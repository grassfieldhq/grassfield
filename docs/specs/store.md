# Store spec · apps-engineer (app), platform-engineer (sources, install path) · owner brief 2026-10-27
Status: step 0 (this spec, ADR-0037 and the parity matrix), revised after the first opus review (FAIL, 3 MAJOR). Step 1
(the read-only backend) is merged; step 2 (the UI, read only: SR1 to SR13 shown, buttons disabled, Installed, the Updates
list, the settings window without its switches; ADR-0037 SD6 to SD10) is built and measured
(`docs/audits/store-2026-10-27/step2.md`); install, open and uninstall are step 3 (3a repository packages and web apps,
3b1 Omarchy's setups, and 3b2 the AUR, merged; 3c Flathub: part 1 merged, part 2, the Flathub source, built
(`docs/audits/store-2026-10-27/step3c.md`), part 3 "Get Flatpak…" merged); step 4 (the Updates page with Flatpak updates, the
sidebar's count, the search by document type for Files, one Store per user; ADR-0037 SD32 to SD35) is built
(`docs/audits/store-2026-10-27/step4.md`). The owner answered ADR-0037 ST1 to ST10 on 2026-10-27 (in the owner's own words in the ADR): §4 amended; AUR and Flathub both
off until turned on; the sheet alone for per-user installs; repository packages through the Store's root helper behind
polkit, the AUR and Omarchy's recipes in Omarchy's terminal; Arch's AppStream from its package, else fetched; screenshots
when a product page opens; the AUR's web service; the only update badge on Settings; the proposed step order; publishers'
icons in our catalog for apps without metadata.
Decisions and evidence: `docs/decisions/ADR-0037-store.md` (probes S0 to S18). Parity and measures:
`docs/audits/store-2026-10-27/parity.md`. App id `org.grassfield.Store`, binary `grassfield-store`, package `grassfield-store`.
Name: "Grassfield Store" in both languages (a product name). Never "App Store" or "Arcade" (§14). The name and the
sidebar's structure need legal review (ADR-0037 e.10).

## macOS reference behavior (described in words; no Apple image committed)
- One window with the macOS 27 unified sidebar: the search field at the top of the sidebar, then Discover, Arcade, Create,
  Work, Play, Develop, Categories, Updates; the account (initials circle, name, a red count badge) at the bottom.
- Discover: a large bold title, a carousel of large artwork cards (eyebrow in capitals, title, one line), then rows of
  smaller cards two by two with an eyebrow, a title, a grey subtitle and a round artwork (measures in the parity matrix).
- Search: words in the sidebar field and Return; results with their buttons.
- An app's page: screenshots, ratings and reviews, events, developer, size, compatibility, languages, age rating,
  accessibility, privacy. The price or "Get" button starts the download after the account's authentication; progress shows
  on the button with Pause and Resume; "Open" once installed.
- Updates: a list with "Update" per app and "Update All"; a badge on the Dock icon and a count in the sidebar; a
  notification with "Install". Uninstalling is not done in the store (Apps or Finder).
- Shortcuts: Command-1 to Command-8 for the sidebar items, Command-F search, Command-R refresh, Command-[ back.

## Purpose and non-goals
Purpose: find an app (Discover, sections, Categories, search), see what it is (source, licence, metadata), install it with
the user's explicit consent and authentication, open it, uninstall it, and see which installed apps the next system update
brings, on Grassfield over an unmodified Omarchy 4.

Non-goals:
- no account, purchase, payment, subscription, gift card, Family Sharing, region, content restrictions;
- no ratings or reviews (no identity leaves the machine); no stories, events, videos;
- no per-app update of repository or AUR apps (Arch: no partial upgrade; Flatpaks have one), no automatic updates, no pause
  or resume;
- no `pacman -Sy`, no `--overwrite`, no removal of `db.lck`; the only root code is `grassfield-store-helper`, which runs
  pacman on validated repository names (ADR-0037 b.1);
- no installer of its own: pacman, yay, flatpak and Omarchy's commands install (ADR-0037 b);
- no publication of the catalog before the owner's decision (ADR-0033 h).

## Functional requirements
Window and navigation (step 2)
- SR1. One window `org.grassfield.Store`, the macOS 27 structure of the parity matrix: sidebar flush with the window, the
  search field at its top, the sections, then Categories and Updates; at the bottom the local user's row (initials or the
  user's picture from AccountsService, the full name) that opens **Installed**. Tokens only (`ui/Grassfield/Ui/Tokens.qml`,
  new `store.*` tokens with their source note); the shared components first (`SearchField`, `Material`, `Button`,
  `ProgressBar`, `Sheet`, `PopupMenu`, `ScrollBar`, `Tooltip`, the sidebar rows of Settings and Files); light and dark;
  Reduce Transparency and Reduce Motion honoured. F1 strict (ADR-0024): geometry ±1 pt, tints ±0.1, A2 contrast.
- SR2. The sections between Discover and Categories come from the verified catalog (ADR-0037 g), in its order, with its
  titles (en, fr) and symbols. Without a catalog only Discover (AppStream-based, no editorial block), Categories, Updates
  and Installed are shown.
- SR3. Back and forward in the toolbar capsule (as Settings): a product page or a category list pushes; Back returns with the
  scroll position kept.

Discover and sections (step 2)
- SR4. Blocks: `hero` (the carousel: 880 x 340 at the reference width, radius 12, the next card peeking 20; arrows on hover;
  the artwork is Grassfield's: the app's icon large on a tint derived from its colours), `cards` (two per row, 430 x 230,
  fill and type per the matrix, the app's icon in the round artwork place), `row` (a titled horizontal list of apps: icon,
  name, summary, button). Widths follow the window: the content keeps 40 pt margins; below the reference width the cards
  become one per row.
- SR5. Every card and list item shows the app's source badge; a click opens the product page; the item's button acts as on
  the product page.

Search (step 2)
- SR6. Typing in the sidebar field (Ctrl+F focuses it) shows results while typing from the local merged catalog (our catalog,
  AppStream, the `[omarchy]` list): name, keywords, summary and package name, ranked name-prefix first; Esc clears, then
  leaves the field. Empty result: "No Results for “…”" (« Aucun résultat pour « … » »). The search runs on a worker
  (`searchAsync`, SU-06): typing asks once keys pause (120 ms), an answer to an older query is dropped, and "No Results" waits
  for the answer. The result lists, a category, Installed and a type's apps are virtualized grids (AppGrid: a GridView the
  size of what the page shows, delegates reused, a model keyed by app id); a new snapshot updates the page shown in place
  (its lists change row by row, its scroll and focus stay), and a change of the buttons' state alone (`revisionChanged`: a
  Flatpak update checked or planned) re-reads only the buttons. A screenshot the page no longer wants is cancelled: it
  leaves the queue, or its transfer stops.
- SR6b. The search by document type (step 4, ADR-0035 5c-3, ADR-0037 SD34): `--page=type:<type>` (what Files' "Search the
  Store" opens when no application opens a document) lists the apps whose AppStream says they open the type (`<provides>
  <mediatype>`, the older `<mimetypes>`), those of the type itself first, then those of its parents in the MIME
  database's order (a C file: text editors), by name in each; titled "Apps for “PNG image” Documents" (« Apps pour les
  documents « … » »), else "No apps in the Store open “…” documents." A malformed type opens nothing. A second launch
  hands its page to the running Store (one Store per user, SD35).
- SR7. AUR results (only when the AUR source is turned on, ADR-0037 ST2/ST7) appear after Return in their own section "From
  the AUR (not reviewed)" (« Depuis l'AUR (non vérifié) »), with votes and the out-of-date flag: the AUR's search by name,
  the most voted first (at most 50), the names a repository has left out (their own pages install them). Until Return,
  one line says "Press Return to search the AUR too." (« Appuyez sur Entrée pour chercher aussi dans l'AUR. »); then
  "Searching the AUR…", or why there is nothing: offline, fewer than two characters, too many results ("type more of the
  name"), the AUR unavailable, or "The AUR has nothing for “…”". An answer for an older query is dropped.
- SR7b. Flathub apps (only when Flathub is turned on, ST2) are part of the local search (their AppStream is in the user's
  installation), each with the "Flathub" badge.

Categories (step 2)
- SR8. A grid of the catalog's categories (symbol, name); a category opens its list, sorted by name, with a source filter
  (All, and one per enabled source). Apps that our catalog does not list are placed by their AppStream categories.

Product page (step 2)
- SR9. Header: icon, name, summary, developer, the button (SR13), source badge and licence ("Licence not stated" when none).
- SR10. Screenshots (when AppStream has them; loaded when the page opens unless turned off, ST6), a gallery with arrows; description (plain text,
  paragraphs and bullets); What's New (AppStream releases, else the version and the package's build date).
- SR11. Information: Source (with the repository, e.g. "Arch Linux · extra", "Omarchy", "Omarchy setup", "Web app", "AUR"),
  Package, Version, Download size, Installed size, Category, Languages (AppStream), Content rating (OARS, else "Not rated"),
  Licence, Homepage and Bug tracker (buttons that open the browser on click, https only). For an Omarchy setup: "What this
  setup changes" (our catalog's text) and the recipe's name. For the AUR: Maintainer (or "Orphaned"), Votes, Popularity, Last
  updated, "Flagged out of date" when so, and "View Build Script" (the PKGBUILD as plain text in a sheet, fetched on click).
  For a Flatpak: the app id, the runtime and
  Flathub's verified-developer flag when its AppStream carries one; then, under Information, "Permissions"
  (« Autorisations », ADR-0049): every grant of its metadata in plain words on cards grouped as the App Store's privacy
  section (Files and Folders with each folder and its mode, Network, Camera and Other Devices, Microphone and Speakers,
  Display, Keys and Passwords, Other Apps and Services, Background and Login, Outside Its Sandbox, Other), a short note
  under a wide grant, X11 apart from X11 only where Wayland is missing (none in this session), raw USB apart from the USB
  portal's devices and those hidden from it, a bus name or a grant the Store does not know named as flatpak writes it; one card "Only Its Own
  Window and Files" only when nothing more is granted; nothing when its metadata could not be read (ADR-0037 SD25).
- SR12. An app with several launchers names the one "Open" uses; an app with none (a command-line tool) says so and has no
  "Open".

Get, Open, Uninstall (step 3; the paths of ADR-0037 b, owner ST4)
- SR13. The button: "Get" (« Obtenir ») when not installed; "Open" (« Ouvrir ») when installed with a launcher ("Update"
  « Mettre à jour » for a Flatpak with an update; never for a repository or AUR app); a progress
  ring while its operation runs or waits in the queue ("Waiting" « En attente »); "Installed" (« Installée ») when installed
  without a launcher. Disabled with a tooltip when offline, while an update or another package manager runs, or when the source
  is turned off; a Flatpak's while Flathub is off ("Turn on Flathub in the Store's settings to install from it.") or the
  `flatpak` package is missing ("Flathub needs the flatpak package."); a setup's, and an AUR
  app's, while the installed Omarchy differs from the catalog's pins or the catalog does not pin the AUR's two commands,
  with that reason (ADR-0037 g, SD19, SD21); an AUR app's while the AUR is off ("Turn on the AUR in the Store's settings
  to install from it.") or when a repository has its name ("A repository has this package: the Store installs it from
  there, from its own page."); an AUR app whose name the deny list names ("The system, Omarchy or Grassfield uses this
  name, so the Store doesn't build it from the AUR." « Le système, Omarchy ou Grassfield utilise ce nom : le Store ne le
  compile pas depuis l'AUR. »; ADR-0037 SD30), or while Omarchy's package lists cannot be read ("Omarchy's package lists
  can't be read, so the Store installs nothing from the AUR."). The ring is the operation's (macOS 27's download ring): its count from pacman's log once there is one (a Flatpak's,
  flatpak's "Installing <ref>" lines against its plan), else turning; a square in it while the operation waits in the
  queue, which takes it out, or while a Flatpak install or update runs, which stops it ("Stop installing …" « Arrêter
  l’installation de … », "Stop updating …" « Arrêter la mise à jour de … », ADR-0037 SD26, SU-09: SIGTERM; what flatpak
  finished stays; an update's later commands do not run; nothing is said). Any Flatpak operation (a removal and its
  `--unused` included) that prints nothing for 30 minutes is stopped the same way and ends "did not finish" (its reason in
  Details), so the queue behind it moves on.
- SR14. "Get" opens the confirmation sheet; its default button is "Install" (« Installer »). For the AUR the button is
  "Install from the AUR" (« Installer depuis l'AUR ») and the default is Cancel: Return and Esc close the sheet, the
  install takes a click or Tab and Space (common rule 3: the build runs the package's script before any password; the
  integrator's decision at 3b2's review). It lists: source, licence, sizes, every package the plan adds (from `pacman -S
  --print` as the user), for a setup first what it changes (our catalog's text) and that Omarchy's recipe (named, with its
  arguments) runs in a Terminal window that asks for the password, for the AUR the warning (SR16), for a Flatpak what it
  can reach and the runtimes it pulls. For the AUR (ADR-0037 SD22) the list has what yay builds, marked "AUR", then what
  pacman adds from the repositories; the sizes are the repositories' part only ("Download from the repositories"), and a
  line says when a dependency could not be read ("the build may install more than this"). Its refusals: a repository has
  the package; it, or a dependency, is neither in the repositories nor on the AUR (named); it would build a package whose
  name the deny list names ("“…” can't be installed from the AUR", "It would build … from the AUR, a name the system,
  Omarchy or Grassfield uses. The Store doesn't install it."; SD30). Cancel (Esc) closes it and nothing runs.
- SR15. Before the operation runs, the plan check of ADR-0037 e.4, and again right before it starts (the helper and
  `grassfield-store-run` check under Omarchy's lock):
  - `pacman -Qu` lists a package not marked "[ignored]" (the last system update did not finish, S12) → "Finish the system
    update first" (« Terminez d'abord la mise à jour du système ») with "Update Now…" (« Mettre à jour maintenant… »),
    which opens Software Update;
  - the system older than its mirror (ADR-0037 e.4, SD29: Software Update's last successful check, whatever its state,
    found other updates or an Omarchy release after pacman last completed a sync of the databases, one that wrote a
    database (S27); or a file of the plan the mirror no
    longer has, every file asked with a HEAD at once before anything downloads, AUR installs included), a
    plan that upgrades an installed package, or an unresolvable plan → "Update your system first" (« Mettez d'abord le
    système à jour »): "Your system needs to be updated before you can install apps. Software Update brings it up to date;
    then get the app again." with "Update Now…". An install pacman ended because the mirror answered 404, 410 or too
    much for a package or its `.sig` ends the same way: "Your system needs to be updated before you can install apps."
    (« Votre système doit être mis à jour avant que vous puissiez installer des apps. ») with "Update Now…" in the notice
    and on the app's page, no "Try Again" and no "Details…". The mirror's and pacman's words go to the log only; the
    Store never refreshes the databases alone;
  - `db.lck` present or Omarchy's update lock held → "Another installation or an update is running" (« Une autre installation
    ou une mise à jour est en cours »).
  Nothing is queued then. The web apps and Flatpaks, which pacman does not install, skip the first two checks.
- SR16. The AUR warning, on the sheet, every time (en / fr):
  "AUR packages are made by users and reviewed by no one, neither Arch Linux nor Grassfield. Their build script runs on this
  computer and the package is then installed with administrator rights. Install only what you trust." /
  « Les paquets de l'AUR sont faits par des utilisateurs et ne sont vérifiés par personne, ni Arch Linux ni Grassfield. Leur
  script de construction s'exécute sur cet ordinateur, puis le paquet est installé avec les droits d'administrateur.
  N'installez que ce en quoi vous avez confiance. »
- SR17. The authentication (owner, ST4 and ST3): repository packages, the polkit dialog of `grassfield-store-helper`
  (Grassfield's polkit sheet; "Waiting for permission…" « En attente de l'autorisation… » meanwhile, 120 s at most, then the
  Store ends pkexec and says the request timed out, SD16), at every
  operation, never kept (`auth_admin`: a queue of three operations asks three times), the sheet saying "Install xterm, gimp"
  or "Remove …" with every package name polkit reports (past eight lines the list scrolls), then "Action:
  org.grassfield.store.manage-packages" and "Program:
  /usr/lib/grassfield/grassfield-store-helper" (ADR-0037 b.1, SD2, SD17; the line as polkit gives it when it does not
  match); the AUR and
  Omarchy setups, sudo's prompt in Omarchy's terminal; web apps and Flatpaks, the sheet alone, its default button being the
  consent.
- SR18. One operation at a time, whatever its path; later ones wait in the queue (shown on their buttons and in a queue
  popover in the toolbar: a button while the queue holds anything, whose menu lists each operation with what it does, and
  "Don't Install “…”" for a waiting one). The next one starts only when the previous one has its exit
  code, Omarchy's update lock is free and `db.lck` is absent. Its record is written to store.json on a writer thread before
  it starts (never on the click path). `grassfield-store-helper` runs pacman in the transient system service
  `grassfield-store-helper.service` (`systemd-run --wait`, KillMode=mixed, TimeoutStopSec=30 min, as
  grassfield-update-helper does, SU-03) under a sleep, idle and shutdown inhibitor while pacman runs: a log out, a shutdown
  that stops the user's manager or the Store's end cannot kill pacman mid-transaction; a stop of the unit before pacman
  changes anything ends the run (exit 1), after that it goes on to its end. The Store follows the unit by its status files
  (`<op>.started`, `<op>.exit`) when pkexec ends first, as after a restart. The running one shows progress: indeterminate while
  downloading, then "n of N" from pacman's log; in Omarchy's terminal it also says so ("Opening Terminal…" « Ouverture du
  Terminal… » until the script started, then "Installing in Terminal…" « Installation dans le Terminal… » or "Uninstalling
  in Terminal…" until pacman's log counts). While an operation runs, Omarchy's update lock is held, by the Store for the
  helper's and by `grassfield-store-run` for a setup's (ADR-0037 b.2; the Store only checks it is free before it asks for
  the terminal): `omarchy update` cannot start, and Software Update, which reads the same lock, shows "Update in progress"
  (ADR-0033 d.5, in its own words) until the operation ends.
- SR19. Every operation ends with an exit code the Store receives (ADR-0037 b): pkexec's (b.1), the `exit` file of
  `grassfield-store-run` (b.2), the child's (b.3). Success is that code being 0 **and** the system's state matching the plan
  (the packages present at the planned versions, the web app's entry present, the Flatpak listed). Then the button becomes
  "Open". Otherwise one line under the button and a "Details" popover (pacman's message from the helper's log or the
  terminal, and what to do); "Try Again" re-runs the same plan. The helper's exit code says which line (ADR-0037 b.1): 3
  another installation or an update is running, 4 finish the system update first, 5 update your system first, 6 the app
  can't be uninstalled from the Store, 7 the package isn't an app, 1 the installation failed; pkexec's 126 is a dismissed
  request (nothing said) and 127 a refused one. `grassfield-store-run`'s (b.2): 3 and 4 as the helper's, 5 "This setup
  hasn't been checked with your version of Omarchy yet" « Cette configuration n'a pas encore été vérifiée avec votre version
  d'Omarchy… », 6 (too late) "The terminal did not open", 1 the installation failed, 130 (Ctrl+C in the terminal) nothing
  said when nothing changed. The same line shows at the bottom of every other page while the result
  stands, with Try Again, Details… and Close (the app's own page has it under its button only). Time limits: the polkit dialog 120 s; Omarchy's terminal must
  start the script within 60 s ("The terminal did not open" « Le terminal ne s'est pas ouvert »); a running operation is
  followed up to 2 h (helper) or 3 h (terminal), then the Store says it lost track and reads the state; it never stops one.
- SR20. Recovery at start (ADR-0037 f): an operation recorded in `store.json` is compared with its `exit` file, its running
  helper or script, and the system, and reported as done (silently), still running (followed again), interrupted ("15 of 110
  packages were installed", with "Try Again"), or not finished; a stale `db.lck` is explained with Arch's recovery as text to
  copy, never removed by the Store (a notice at the bottom of the page, its Details… showing `sudo rm
  /var/lib/pacman/db.lck` to copy, only when no pacman runs). Closing the window while an operation runs leaves the Store
  without a window until it ends (SD13).
- SR21. "Open" starts the app through ADR-0011 (`uwsm-app -- <desktop-id>` in a real session, `apps/appscope.h`); a web app
  with `omarchy-launch-webapp <url>` (its entry's file name has spaces, which uwsm refuses, S14); the Store stays open. In a
  dev session only fixture apps open (ADR-0011 dev open policy).
- SR22. "Uninstall…" (« Désinstaller… »): in the product page's "…" menu, in Installed, and in the context menu of an installed
  app's item (Open, Show in Store, Uninstall…). The launcher's delete badge and Files' Move to Trash on an application hand the
  app over (`--page=uninstall:<entry>`, ADR-0046): the Store opens its own alert "Delete “App”?" (its name, its icon, the
  packages the plan takes, Cancel the default) and removes nothing until Delete is pressed in it; a hand-over never runs an
  operation by itself. Installed's web apps that our catalog does not list (Omarchy's own, the
  user's) open and uninstall too (SD15). Its sheet lists what goes: the packages (the plan of `pacman -Rns`, asked as `pacman -Rs --print` by the user,
  S10; for an AUR package the same plan, removed through Omarchy's `omarchy-pkg-drop` in a Terminal window that asks for
  the password), or the setup's removal recipe (named, in a Terminal window that asks for the password), the user data it deletes
  (our catalog's `removes`, "It also deletes: …" « Elle supprime aussi : … ») and its packages (the same plan; a setup
  whose package the deny list names offers no "Uninstall…"), or the web app's launcher and
  icon, or the Flatpak (its data in `~/.var/app/<app-id>` stays, and the sheet says so). A package other installed packages
  need is not removable (S10: "removing glib2 breaks dependency … required by
  accountsservice"): the sheet says which ones need it, and nothing runs. Default button "Uninstall" (« Désinstaller »),
  destructive style. "Uninstall…" exists only for an app the user installed (ADR-0037 a, b.1; S16): a package installed
  explicitly that owns an application entry (an AUR package needs no entry), that the deny list does not name, and whose whole
  removal plan names no denied package. Otherwise no "Uninstall…", and the page says why: "Part of Omarchy" (« Fait partie
  d'Omarchy »: Omarchy's two package lists, such as Chromium), "Part of Grassfield" (« Fait partie de Grassfield »), "Part
  of the system" (« Fait partie du système »: the kernels, firmware, boot tools, `base`, `sudo`, `systemd`, pacman,
  `HoldPkg`), "Installed with another app" (« Installée avec une autre app »: a dependency), or, when the plan would take a
  protected package with it, "Uninstalling it would also remove part of the system" (« La désinstaller retirerait aussi une
  partie du système »). From the repositories, the Store offers only apps that own an application entry (SD1), so it can
  remove whatever it installed from them.

Installed (step 2 read-only, step 3 actions)
- SR23. The apps installed from the Store's sources that have a launcher or a catalog entry: explicitly installed packages
  (`pacman -Qe`) with an AppStream or catalog entry, setups whose packages are present, Omarchy web apps
  (`~/.local/share/applications/*.desktop` whose Exec is `omarchy-launch-webapp`), packages no repository has (`pacman -Qm`:
  "Not from a repository" « Hors dépôts »; while the AUR is on, those installed explicitly that the AUR knows form the
  "AUR" group, with their AUR pages; Grassfield's own local builds never listed), Flatpaks of the user's installation (`flatpak list --user --app`, when Flathub is on). Each with Open and, unless
  protected (SR22), Uninstall…. Grouped by source, sorted by name.

Updates (step 4; ADR-0037 d, owner ST8)
- SR24. From ADR-0033's result (`software-update.json`, watched): the installed apps with an update, each marked "Updates
  with the system" (« Mise à jour avec le système »), then "N other system packages", the Grassfield and Omarchy releases as
  Software Update names them, and "Update All…" (« Tout mettre à jour… »), which opens Software Update (Settings > General),
  where Update Now updates the whole system with its password and its progress (SD32); "Software Update…" (« Mise à jour de
  logiciels… ») instead when only it can act (updates blocked, not set up). "Check Now" (« Vérifier maintenant ») asks the
  shell to check (`qs ipc … update check user`, ADR-0033 d.7), reads `pacman -Qu` and checks Flathub; the page checks
  likewise when it opens, unless a check finished less than a minute ago, and follows Omarchy's update lock every 2 s while
  shown. States, first that applies: "Update in progress" (the lock held by another program, or the checker says so),
  "Checking for updates…", "The last system update did not finish." when `pacman -Qu` lists packages not "[ignored]" while no
  update runs (S12; with what it means and Update All…), then the checker's own (up to date with the last check time,
  available, failed, blocking, not set up), or "Software Update couldn't check for updates. Open it to check." when the shell
  did not answer.
  Flatpaks (Flathub on) form their own group, "Flatpak Apps" (« Apps Flatpak »): Flathub's updates of the user's
  installation (`flatpak remote-ls --user --updates`, S31; another remote's are the user's own), checked when the Store
  opens, on "Check Now", when the page opens (unless checked less than a minute ago) and after each Flatpak operation; each
  app with "Update" (« Mettre à jour »), the runtimes counted, and "Update All" (« Tout mettre à jour ») for the group. An
  update starts at once, unless it lets an app reach more than the installed version can, or that could not be read: then
  a sheet says what it adds first (SD33, SD25 for an update); while its plan reads each app's commit and access, the
  group's line says "Checking what the updates change: N of M apps…" ("Checking what the update changes…" for one app) and
  the app's Update waits. Each app is updated to the commit its plan checked (a newer one published meanwhile is listed
  again and asked about again, S32), unless it was updated outside the Store since its plan (another commit installed):
  then it is left as it is, never downgraded; it is done when that commit is installed (an unpinned ref: when a new check
  no longer lists it), never on flatpak's exit code alone (offline it exits 0 with "Nothing to update.", S31d). After each
  check every app's update is reviewed (ADR-0049, as pessimistic as flatpak's own check: the installed metadata read
  narrowest, the newer widest; a folder inside one it had, X11's fallback to X11, a USB device no longer hidden, create
  after read and write are more): one that asks for more (a grant added or widened) or could not be read
  says "Asks for more: …" (« Demande davantage : … ») where its summary is, and the group says "Apps that ask for more
  than before update only when you update them one by one."; Update All takes every other listed update, at once and
  without a sheet, and leaves those to their own Update, whose sheet lists what the app can newly reach and what it no
  longer can; everything held, Update All's sheet says to update them one by one.
- SR25. The sidebar's Updates row shows the number of apps with an update, Flatpaks included. The Store's Dock tile has no
  badge: the only update badge is Software Update's, on Settings (owner, ST8).

Catalog and network (step 1)
- SR26. The catalog is fetched at start when the cached one is older than 6 h, and on Ctrl+R (« Actualiser »), never while the
  Store is closed, never on a metered connection without Ctrl+R; verified (`gpgv` with the keyring of
  `/usr/share/grassfield/pacman-keyring/`, VALIDSIG argument 10 in its `grassfield-trusted`, not in its `grassfield-revoked`),
  validated, then cached; a lower serial than the accepted one is refused (ADR-0037 g).
- SR27. Requests per ADR-0037 c: https only, no cookie, no referer, User-Agent `Grassfield-Store/1`, 15 s, size caps. No search
  query leaves for Grassfield's host. The Store's settings window lists what is fetched and from where, in plain words.
- SR27b. Arch's AppStream (owner, ST5): the installed `archlinux-appstream-data` when there is one; otherwise the Store fetches
  that package's file and its `.sig` from pacman's own mirror (`pacman -Sp`), checks the signature as pacman does, as the
  user (gpg against a private copy of pacman's keyring: one good detached signature by a key fully trusted and not
  disabled; S17, S19, SD4; a failed check keeps nothing and says "Arch's app data could not be verified" « Les données
  d'apps d'Arch n'ont pas pu être vérifiées » in the settings window; a download that failed, the package's or its
  `.sig`'s, says "Arch's app data couldn't be downloaded. Check for updates, then try again." « Les données d'apps
  d'Arch n'ont pas pu être téléchargées. Recherchez les mises à jour, puis réessayez. » with "Open Software Update"
  « Ouvrir Mise à jour de logiciels », in the settings window and on a page left empty; anything else, unavailable),
  and keeps its XML
  and icons in its cache (64 MiB at most), replaced when pacman's database names another version. Used for
  display only: a package it names must exist in pacman's database.

Settings window (Ctrl+, ; step 2 reads, step 3 writes)
- SR28. "Sources": switches for the optional sources, both off until turned on, each with one line saying what it means: AUR;
  Flathub, shown only when the `flatpak` package is installed. Without it, the line "Flathub needs Flatpak, which installs
  its apps in your own folder." and "Get Flatpak…" (ADR-0037 SD24): its sheet, over the settings window, says what Flatpak
  is, that Omarchy installs it in a Terminal window that asks for the password, and that the apps reach the launcher after
  the next login, then pacman's plan; Install runs Omarchy's `omarchy-pkg-add flatpak` in its terminal (b.2), the line says
  so while it runs and how it ended when it did not install it; dimmed, with why, while the catalog does not pin the
  command or Omarchy differs from its pins; "Flathub needs the flatpak package." without Omarchy's terminal. With Flathub
  on and before the next login, "The apps you get from Flathub show in your app launcher after you log in again." Turning
  Flathub on adds the Flathub remote to the user's installation
  (`flatpak remote-add --user --if-not-exists`) and fetches its AppStream; while it could not be added (offline, Flathub
  unreachable) the line "Flathub couldn't be reached. The Store adds it once you're online; Refresh tries again."
  (« Flathub n’a pas pu être joint. Le Store l’ajoute dès que vous êtes en ligne ; Actualiser réessaie. »). "What the
  Store Fetches" says what flatpak fetches from Flathub while it is on.
  "Screenshots": the ST6 switch. "Catalog": the channel and the date of the catalog in use, "Refresh". Stored in
  `grassfield.json` (`store.sources.aur`, `store.sources.flathub`, `store.screenshots`), written by the Store with the
  settings contract's rules as Settings writes its own keys, until the shell is the single writer (ADR-0020 item 4,
  ADR-0037 SD20); a change made elsewhere is followed while the Store runs. Turning the AUR off hides its results, pages
  and group at once. "What the Store Fetches" names what the AUR is sent whether it is on or off (read before turning it
  on); while it is on, its closing line says that Return sends the search to the AUR and that a metered connection
  still lets through what the user asks for (Refresh, Return, an AUR page); nothing is asked by itself there (the
  foreign packages' names wait for an unmetered connection).

Offline
- SR29. ADR-0037 "Offline": the bar "You're offline. The catalog is from 27 October." (« Vous êtes hors ligne. Le catalogue date
  du 27 octobre. »), Get and Update All disabled with the reason, Open and Uninstall available, uncached screenshots replaced
  by a placeholder; a catalog older than 30 days is used with a note.

Dev sessions (ADR-0019)
- SR30. No real operation, ever: no pkexec, no Omarchy terminal, no flatpak operation; the queue runs fake programs only
  (`GRASSFIELD_STORE_PKEXEC` for the helper's path, `GRASSFIELD_STORE_INSTALLER` for the others, the fixture's `bin/flatpak`
  for Flathub's); catalogs, keyrings and package roots from fixtures (`GRASSFIELD_STORE_CATALOG_URL`,
  `GRASSFIELD_STORE_KEYRING`, `GRASSFIELD_STORE_FIXTURE`); without them the buttons show "dev: not applied", and Flathub is
  read but never added to the user's installation.

## Keyboard
| Keys | Action |
|---|---|
| Ctrl+1 … Ctrl+n | the sidebar items in order (Discover, the sections, Categories, Updates) |
| Ctrl+F | focus the search field |
| Ctrl+R | refresh the catalog (and the page) |
| Ctrl+[ / Ctrl+] , Alt+Left / Alt+Right | back / forward |
| Ctrl+, | the Store's settings |
| Ctrl+W, Ctrl+Q | close the window, quit (a running operation goes on, ADR-0037 f) |
| Tab / Shift+Tab | sidebar → content → toolbar; inside the content, the cards and buttons in reading order, each scrolled into view below the toolbar |
| Arrows | inside a carousel or a grid, move between items; Up/Down in the sidebar |
| Return / Space | open the focused item / press the focused button |
| Esc | close a sheet or popover (Cancel); in the search field, clear then leave |
Shortcuts are shown in the menus in the user's shortcut style (`apps/shortcutstyle.h`). The menus are exported to the menu bar
(T1, as the other apps), between the shell's app menu (About, Quit) and Window (T0, ADR-0008): File (Settings…, Close
Window), Edit (for the search field, and Find), View (the sidebar items, Back, Forward, Refresh). "Settings…" is in File
because the app menu is the shell's (ADR-0037 SD6); without a global menu bar the toolbar shows a gear for it.

## Accessibility
- Every control reachable by keyboard with a visible focus ring (A1); `Accessible.name`, `role` and `description` on the
  sidebar rows, cards ("<app>, <source>, <summary>"), buttons ("Get <app>", "Open <app>", "Uninstall <app>"), the progress ring
  (value and "n of N"), the badges and the warning (role alert).
- Progress and results are announced (live region) when they change state; never more often than once a second.
- Text over the hero tint meets A2 (≥ 4.5:1) in both appearances: the tint is darkened as needed, never the text lightened.
- Reduce Motion: the carousel does not auto-advance (it never does by default) and page pushes cross-fade (≤ 100 ms).
- Screenshots have their caption (AppStream) as accessible text, else "Screenshot n of N of <app>".

## i18n (en and fr)
- Every visible string in `qsTr()`; the fr catalog complete (I1). Our catalog's texts carry `en` and, when written, `fr`; the
  Store shows `fr` when the session's language is French and the field has it, else `en`. AppStream texts use their
  translation for the language when present.
- Sizes and dates in the user's region (`region.formats`, as Settings): « 12,4 Mo », "12.4 MB"; "27 October" / « 27 octobre ».
- The main labels: Discover / Découvrir, Create / Créer, Work / Travailler, Play / Jouer, Develop / Développer, Categories /
  Catégories, Updates / Mises à jour, Installed / Installées, Search / Rechercher, Get / Obtenir, Open / Ouvrir, Install /
  Installer, Uninstall… / Désinstaller…, Update All… / Tout mettre à jour…, Try Again / Réessayer, Licence / Licence, Source /
  Source, Omarchy setup / Configuration Omarchy, Web app / App web, Not rated / Non classé. (The section titles come from the
  catalog.)

## Refusals (what is refused, and what the user sees)
| Case | Behaviour |
|---|---|
| A plan that upgrades an installed package or cannot be resolved (database newer than the system, S4) | sheet: "Update your system first", "Your system needs to be updated before you can install apps. …", "Update Now…"; nothing runs |
| The system older than its mirror: Software Update's last successful check (up-to-date, available or not-set-up) found other updates or an Omarchy release after pacman last completed a sync (S27), or a file of the plan the mirror no longer has (HEAD 404/410; S5; SD29) | same sheet, before anything downloads; the mirror's answer in the log only |
| An install pacman ended on the mirror's 404, 410 or oversized answer for a package or its `.sig` | "Your system needs to be updated before you can install apps." with "Update Now…" (notice and page), no Try Again, no Details…; pacman's output in the log |
| `pacman -Qu` lists packages not "[ignored]" (the last system update did not finish, S12) | "Finish the system update first", "Open Software Update"; nothing installs from a repository, the AUR or a setup |
| `db.lck` present, or Omarchy's update running (S11) | "Another installation or an update is running"; nothing queued |
| An exit code 0 without the planned state, or the planned state without an exit code | "interrupted" (SR20), never "installed" |
| Omarchy's terminal does not start the script within 60 s | "The terminal did not open"; the late script refuses to start |
| "Uninstall" of a package of Omarchy's two lists, Grassfield's packages, the system's (deny list, `HoldPkg`), a dependency, a package without an application entry (from a repository), or a package whose `-Rs --print` plan names a protected one | not offered, with the reason (SR22); the helper refuses them too (ADR-0037 b.1) |
| A fetched AppStream package whose signature does not pass pacman's rule (ADR-0037 c, S19) | not used, not cached; "Arch's app data could not be verified" in the settings window; pacman's descriptions only |
| Arch's AppStream package, or its `.sig`, that could not be downloaded | "Arch's app data couldn't be downloaded. Check for updates, then try again." with "Open Software Update" (settings window, an empty page); the catalog alone is used, or nothing (Try Again) |
| A catalog whose `channel` is not the channel it was fetched from | not used, as a bad signature |
| A stale `db.lck` with no pacman running | an explanation and Arch's recovery as text; the Store never removes it |
| An uninstall that would break another installed package | the sheet names the packages that need it; nothing runs |
| A catalog with a bad or missing signature, a key not trusted or revoked, a lower serial, an invalid top level | not used, not cached; the previous catalog stays; one line in the settings window "The catalog could not be verified" |
| A catalog entry that breaks a rule (unknown repo, bad name, http URL, oversized icon, wrong hash) | that entry is dropped, the rest is used |
| A recipe the installed Omarchy does not have | the setup is hidden |
| A file the catalog pins differs or is missing in the installed Omarchy (an Omarchy update the catalog has not checked yet) | every setup's Get and Uninstall… dimmed with "This setup hasn't been checked with your version of Omarchy yet" (SD19); the plan check and `grassfield-store-run` refuse it too (exit 5), naming the file |
| A catalog without valid Omarchy pins, or a setup whose recipes they do not name | the setup is dropped (ADR-0037 g) |
| An AUR install while the AUR source is off | not offered: "Turn on the AUR in the Store's settings to install from it." |
| An AUR package whose name the deny list names (Omarchy's prefix and lists, `yay`, Grassfield's prefix, the system's, `HoldPkg`), or a plan that would build one; Omarchy's lists unread | not offered ("The system, Omarchy or Grassfield uses this name, …"); the plan refuses a dependency so named; `grassfield-store-run` refuses them too (exit 7; ADR-0037 SD30) |
| An AUR package whose name a repository has | not offered from the AUR (its repository page installs it); the plan and `grassfield-store-run` refuse it too (ADR-0037 b.2, exit 7) |
| An AUR name a repository resolves otherwise (a package that provides it, a group) | the plan refuses it: "A repository has this package, or one that provides it: the Store installs it from there, without building it."; `grassfield-store-run` too (`pacman -Sp`, exit 7) |
| An AUR package, or one of its dependencies, that neither the repositories nor the AUR have | the sheet: "The AUR doesn't have this package (anymore)." or "It needs …, which neither the repositories nor the AUR have."; nothing runs |
| A catalog that does not pin the AUR's two commands, or an installed Omarchy that differs from its pins | every AUR Get and Uninstall… dimmed with "Installing from the AUR hasn't been checked with your version of Omarchy yet" (SD21); `grassfield-store-run` refuses it too (exit 5) |
| The system changed between the sheet and the terminal (a repository has the name now; a package now protected, needed or no longer installed explicitly) | `grassfield-store-run` refuses it under the lock (exit 7), nothing run; "The installation was refused: the system changed since the Store checked it. Try again from its page." (SD23) |
| A web app URL that is not https | not offered (the catalog's CI refuses it too) |
| Offline / metered | Get and Update All disabled with the reason; no automatic fetch on a metered link |
| Dev session | no real operation; "dev: not applied" without a fixture installer |

## Acceptance criteria (each mapped to a test; level)
| Id | Criterion | Test | Level |
|---|---|---|---|
| A1 | a valid fixture catalog signed by a throwaway key is accepted; a changed byte, another key, a revoked key, a lower serial, an oversized file are refused | unit (C++), throwaway gpg homedir | L0 |
| A2 | entry rules: each broken rule drops only its entry | unit with vectors shared with grassfield-packages' validator | L0 |
| A3 | merge: catalog over AppStream over pacman; source precedence; licence fallback | unit with fake AppStream and pacman roots | L0 |
| A4 | search ranking and the AUR section (fake RPC answers) | unit (`tst_aur.cpp`: the answers' rules, the cache; `tst_storebackend.cpp` TheAur through `GRASSFIELD_STORE_AUR_URL`; `tst_storemain.qml` the section and its lines) | L0 |
| A5 | plan check: `pacman -Qu` non-empty (and "[ignored]" lines allowed), a plan with an upgrade, an unresolvable plan, a 404 first package, a held lock → refused with the right message | unit with a fake pacman (`tests/unit/store/tst_plancheck.cpp`; the sheet's words: `tests/unit/tst_storeoperations.qml`) | L0 |
| A6 | queue: one at a time; success = exit code 0 and state (an exit 0 with a partial install, or the state before the exit file, is not "installed"); time limits; `started`/`exit` files of b.2 | unit with the fake programs (`tst_operations.cpp`; b.2's files: its `Terminal*` cases, step 3b1) | L0 |
| A6b | `grassfield-store-helper`: verbs, name patterns, refusals (`-Qu`, `db.lck`), the `remove` rule with S16's cases (system packages, a tool without an entry, a dependency, an Omarchy app, a plan taking a boot tool, Omarchy's lists missing, a plan that does not resolve), the policy's `auth_admin` and message, descriptors not on the caller's pipe, status files; `grassfield-store-run`: arguments, deadline, Omarchy's lock on its own descriptor (closed for the recipe), re-check, the pins, Ctrl+C, exit file | container tests, fake pacman and the real one (step 3: `tests/integration/store_helper.sh`, the deny list on `tests/fixtures/store/removal-vectors.json` for the helper and `tst_removal.cpp`; `tests/integration/store_run.sh` for `grassfield-store-run`, step 3b1) | L1 (container) |
| A7 | recovery: each start case of SR20 | unit with recorded `store.json` (`tst_operations.cpp` RecoveryAtStart; the real helper's files: `store_helper.sh`) | L0 |
| A8 | real install, open (`uwsm-app` argv; a web app by `omarchy-launch-webapp`), uninstall of a repository package (helper), a web app, a setup and an AUR package (terminal script), a small Flatpak (`--user`); a cancelled Flatpak install measured | throwaway Arch container with Omarchy's scripts (step 3; `tests/integration/store_helper.sh`; the AUR with a stand-in yay, since yay's binary comes from GitHub, which the container's network refuses: yay against the real AUR is the owner's A12) | L1 (container) |
| A9 | Discover, a product page, search, Categories, Installed, Updates, sheets, offline bar; light and dark; en and fr | offscreen captures with the fake backend, then a nested shot by the integrator | L0/L1 |
| A10 | F1 geometry and tints against the parity matrix | measurement script on the captures | L1 |
| A11 | keyboard paths and accessible names | QML tests + checklist | L0/L1 |
| A12 | the real polkit dialog of the helper, sudo's prompt in Omarchy's terminal, a terminal closed during an install (SIGHUP through sudo, NOT VERIFIED in S6), the absence of a Store badge, an AUR package installed and removed with Omarchy's own yay against the real AUR | owner, real session | L2 |

## Interfaces / contracts (versions)
- Catalog `grassfield-catalog.v1.json` + `.sig` + `catalog/<sha256>.png` (ADR-0037 g; the contract with grassfield-packages).
- ADR-0033: the channel URL tree and key; `software-update.json` (with the added list of other updates, ADR-0037 d); "Update
  Now"; the request to check.
- `store.json` (state, `version: 1`); Store preference keys in `grassfield.json` (schema, ADR-0020).
- Launch: ADR-0011 (`apps/appscope.h`); web apps by `omarchy-launch-webapp <url>`. Badge: none of the Store's own (ST8);
  Software Update's on Settings (ADR-0033 U18).
- `grassfield-store-helper` (pkexec, polkit action `org.grassfield.store.manage-packages`), `grassfield-store-run` (Omarchy's
  terminal), their status files (`/run/grassfield-store/<op-id>.{started,log,exit}`, `$XDG_RUNTIME_DIR/grassfield/store/
  <op-id>.{pins,started,exit}`, the pins written by the Store): ADR-0037 b.
- Flatpak 1.18 (when installed): `flatpak install|uninstall|update --user --noninteractive`, `flatpak remote-ls --user
  --updates`, `flatpak list --user --app`, `flatpak remote-info --show-metadata`, `flatpak remote-add --user --if-not-exists`.
- Omarchy 4.0.4 commands, pinned in `docs/upstream/omarchy.lock` with the step that uses them: `omarchy-install-app`,
  `omarchy-install-and-launch`, `omarchy-pkg-add`, `omarchy-pkg-aur-add`, `omarchy-pkg-drop`,
  `omarchy-launch-floating-terminal-with-presentation`, `omarchy-webapp-install`, `omarchy-webapp-remove`, the recipes the
  catalog names.
- Environment: `GRASSFIELD_STORE_QML` (the QML directory, as the other apps' `_QML`; the installed one by default). Dev
  plumbing, honoured only in a dev session and inert in a packaged one (ADR-0019, `apps/store/src/storeenv.h`):
  `GRASSFIELD_STORE_CATALOG_URL`, `GRASSFIELD_STORE_KEYRING`, `GRASSFIELD_STORE_FIXTURE`, `GRASSFIELD_STORE_OFFLINE` (`1`:
  offline whatever the network says; tested in `tst_storebackend.cpp` StoreEnv.OfflineOnlyInADevSession; step 3b2:
  `metered` online on a metered connection, `0` online and unmetered, used by StoreBackend.TheAur). Command line:
  `--page` (`discover`, `section:<id>`, `categories`, `category:<id>`, `app:<id>`, `search:<words>`, `installed`, `updates`).
  Step 3a adds `GRASSFIELD_STORE_PKEXEC` (the program run in pkexec's place for the helper's operations) and
  `GRASSFIELD_STORE_INSTALLER` (the program run in place of Omarchy's commands and of Open's launchers: it gets the command's
  name, then its arguments; step 3b1: Omarchy's terminal launcher too); without them a dev session runs no operation ("dev:
  not applied"). With a fixture, the helper's files, pacman's lock and log, Omarchy's folder (its package lists, the setups'
  recipes and pinned files), `grassfield-store-run`'s folder (`<fixture>/run/store`) and `pacman-conf` are the fixture's too.

## Dependencies (versions seen in S3, S8 and S14; checked again at step 1)
`grassfield-desktop` (same version), `kimageformats` (JPEG XL icons), `gnupg` (`gpgv`; AppStream is read by the Store's own reader, ADR-0037 SD5), polkit (`pkexec`,
installed on Omarchy), Omarchy 4.0.4's commands, `pacman` 7.1, `yay` (Omarchy's, only for the AUR); as `optdepends` only:
`archlinux-appstream-data` 20261017-1 (ST5) and `flatpak` (ST2; neither is installed on the owner's machine).

## Degraded behavior
- No catalog (no hosting yet, offline at first start, verification failed): no editorial sections; AppStream and pacman still
  give Discover's lists, Categories and search, and a notice says "The Grassfield catalog isn't available: Arch's apps are
  shown."
- No catalog and no app data from Arch either (both missing, or offline at first start): Discover says "The Store Isn't
  Available Right Now" (« Le Store n’est pas disponible pour le moment »), why in plain words (offline; no trusted key yet;
  no catalog host; the catalog not fetched or not verified; Arch's app data not installed and not fetched, or not
  verified), and "Try Again" (Ctrl+R); never a blank page.
- No `grassfield-keyring`, or one without a key (until the owner's key exists, ADR-0033 O20): the catalog is never used; the
  settings window says why.
- No `archlinux-appstream-data`: the fetched copy (SR27b); before it is fetched, or offline, pacman's descriptions, catalog
  icons where we have them, generic icons elsewhere.
- No polkit agent (no dialog can appear): repository installs fail at once with polkit's refusal, shown on one line.
- Omarchy's commands missing (a non-Omarchy system): no install, no uninstall; the Store browses and opens.
- No shell (Updates): the Store shows the last `software-update.json` and its date; "Check Now" is disabled for system updates
  (Flatpak updates are still checked by the Store).
- No `flatpak`: no Flathub source, no Flatpak group; the settings say how to get it.

## Automated tests · Manual verification steps
- Unit (C++ and QML, offscreen): A1 to A7, A9, A11. Fake pacman (`GRASSFIELD_STORE_FIXTURE`: a script answering `-Sl`, `-Si`,
  `-Q`, `-S --print`, `-Sp`), fake AppStream pool, fake RPC files, throwaway keyring.
- Container (step 3, A8): the real Omarchy commands from a pinned checkout, real pacman installs from a mirror, in a
  throwaway Arch container only.
- Manual, nested (integrator): the visual scenarios; manual, real session (owner): A12.

## Performance (gates affected) · Accessibility · i18n
- The Store is a separate app: no effect on P1/P2 of the shell. Its own budget: first window under 1 s warm with a cached
  catalog; search under 50 ms per keystroke (P4's rule) on 2000 catalog apps plus 1390 AppStream apps; AppStream is read once
  per start in a worker thread; images decode off the GUI thread.
- Accessibility and i18n: above.
- Quitting (SU-07): the bus name `org.grassfield.Store` is released as soon as the Store quits, so a launch meanwhile opens a
  new Store at once; the workers are told to stop (fetches abort within 0.1 s, children get SIGTERM) and are waited for 5 s at
  most, then the process leaves without them. `--removable` runs each repository app's `-Rs` plan on the workers, several at
  once, with the GUI thread free (its 120 s watchdog always fires).

## Known limitations
- No per-app update for repository or AUR apps, and no "Update" button for them: they update with the whole system (Arch).
- No ratings or reviews; the AUR's votes and popularity are its own facts, not ratings.
- No pause or resume. The AUR and setups cancel only in Omarchy's terminal, which can leave a part of the packages installed
  (S6); the Store reports it. Repository installs cannot be cancelled once polkit has said yes.
- Nothing installs from a repository, the AUR or a setup while the last system update is unfinished (`pacman -Qu`, S12).
- Every repository install or removal asks for the password, with no grace period (`auth_admin`); a queue of several asks
  for each.
- "Uninstall…" only for apps the user installed: never for Omarchy's, Grassfield's or the system's packages, a dependency, or
  an app whose removal would take one of them along (SR22); those stay removable outside the Store.
- Apps outside AppStream and our catalog show pacman's one-line description and a generic icon.
- Omarchy's recipes are Omarchy's: their effects are those of the installed Omarchy release; our catalog's text describes the
  release it was written against (4.0.4), and CI checks the names, not the behaviour.
- A replayed old catalog is refused only once a newer one has been seen on that machine.
- Flatpaks are not updated by `omarchy update` (the Store updates them, step 4) and have no Dock badge (ST8). A Flatpak install
  can be stopped (what flatpak finished, runtimes, stays for the next install or the next removal's `--unused`); a removal
  cannot. A Flathub app whose Arch id differs from Flathub's (`firefox.desktop`, `org.mozilla.firefox`) shows once per
  source.
- Screenshots come from third-party hosts (ST6). Apps without metadata show their publisher's icon from our catalog (ST10;
  needs legal review).
- Visual parity of the product page, search, Categories and Updates rests on the guide and the macOS 27 Settings panes: no
  public capture of those pages exists (parity matrix).
