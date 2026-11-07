# Files spec · apps-engineer · M4

## macOS reference behavior (described in words; macOS 27 captures and the parity matrix: "Finder parity matrix" below)
- The file manager is one opaque window: a sidebar on the left (Favorites with the standard user folders,
  Locations with volumes and the network, Tags), a unified toolbar (back/forward, folder title, view switcher for
  icons/list/columns/gallery, action menu, search field), the folder contents, and optional path and status bars
  at the bottom ("12 items, 120 GB available").
- Toolbar (macOS 26/27, ADR-0024 lot 5, C-12): the items sit in 36-pt capsules (see "Toolbar capsules" below); the last
  item is 8 from the trailing edge (`window.itemsInset`), and there is no line under the toolbar until the icons or the
  list scroll under it (or a tab bar sits there).
- Window and sidebar (macOS 27 Finder, ADR-0024 lot 2): a white content area (#292929 in the dark appearance); the sidebar
  a floating panel in `color.*.sidebarFill` (ADR-0024 amendment 2026-11-03), icons in the text colour; 32-pt rows under 34-pt section headers; the current place
  a neutral fill (`files.sidebarSelectionOpacity`, 10 from both sidebar edges, radius 8) under a bold label, not the
  accent. A focused selection in the views is the selection pair (white on the light accent in both appearances).
- Icon view shows large icons or thumbnails with names below; a selected item gets a grey rounded backdrop and an
  accent pill behind its name. List view has sortable columns (Name, Date Modified, Size, Kind), folders show "--"
  as size, dates read "Today at 14:05". Column view shows one column per folder level with a preview column for a
  selected file. Gallery view shows a large preview of the selected item above a strip of thumbnails, with an optional
  preview pane on the right (name, kind, size, dates, tags); Left/Right walk the strip, Space opens the quick look.
- Colour tags: the item menu ends with a row of seven colour dots; clicking one tags the selection (or removes the tag
  when every item has it). Tagged items show small coloured dots next to their names in every view; the sidebar's
  Tags section lists the tags in use, and clicking one shows the tagged items.
- Tabs appear from the second tab (Cmd+T), or always with View > Show Tab Bar (Shift+Cmd+T); a tab drags to reorder,
  onto another window or out to become a window (section "Tabs and windows"). Get Info opens a small separate window per item. Space opens
  Glance. Type-to-select jumps to the first matching name. Drag and drop moves on the same volume and copies
  across volumes.

## Purpose and non-goals
Browse and manage files on KDE Frameworks KIO (owner decision D6): the feature is called "Files" (code
`grassfield-files`, app id `org.grassfield.Files`; never "Finder"). Trash, mounts, network protocols and thumbnailers
are KIO/Solid's, never reimplemented. Non-goals for v1: an indexed search (the shell Search covers files; the tag
search walks one folder tree, F16), named tags created in Files (only the colour tags are set here; tags of other
applications are shown, kept and searchable), sharing services of its own (the Share menu offers LocalSend, Omarchy's,
since ADR-0045 OC-13: see "Share menu" below), a built-in viewer (Space
starts Glance of `grassfield-preview`, see `docs/specs/preview.md`). Recents and Group By arrived with PR 2 ("Views and
selection").

## Functional requirements
1. F1 Launcher `apps/files/src/main.cpp`: `QApplication` (KIO's widgets library expects one; its dialogs are Grassfield sheets, ADR-0035 D-12 a),
   `setDesktopFileName("org.grassfield.Files")`, `grassfield-files [locations...]` opens one window per location
   (default: home). QML from `GRASSFIELD_FILES_QML` or the baked-in directory (installed
   `/usr/share/grassfield/files/qml`). Image providers `image://icon/<theme name>` and `image://thumbnail/<id>`. Everything
   but `main.cpp` is the Files library (`apps/files/files-core.cmake`, a static library) that `grassfield-portal` links too:
   its Open and Save panels (`FilePanels.qml`, `FilePanel.qml`; ADR-0035 D-4, `docs/specs/system-dialogs.md` section 1) are
   Files' browser, with a tab that browses for a panel (`BrowserTab.chooser`: no file operation, items the panel cannot take
   dimmed through `FolderModel.chooser`).
2. F2 Listing: `FolderModel` = KIO `KDirModel` (+`KDirLister`) behind a `QSortFilterProxyModel` with flat QML roles
   (name, url, iconName, isDir, size(Text), modified(Text), kind, thumbnail, largeThumbnail, selected, hidden, canPreview,
   emblem, tags, tagColors, folderColor, folderGlyph, group).
   Sort By the eight keys of "Views and selection" (Name natural and case-insensitive, Kind, Application, Date Last Opened,
   Date Modified, Date Created, Size, Tags) and Group By; Keep Folders on Top; ascending/descending (the dates and Size
   default descending, the others ascending: `FileLogic::defaultDescending`); show hidden files; name filter (search field).
3. F3 Selection: click, Shift (range), Ctrl (toggle), Ctrl+A, rubber band (icon, list and column views), keyboard arrows, Home/End,
   PageUp/PageDown, type-to-select (1 s reset). The selection is keyed by URL and survives re-sorting.
4. F4 Views: Icon (thumbnails), List (sortable headers), Columns (miller columns + preview column), Gallery (F15);
   Ctrl+1/2/3/4, View As (item and background menus), the global View menu and the toolbar switcher. The view and the
   sort chosen in a folder are that folder's (decision F-3, `files-views.json`): a folder opens in its own view, a folder
   without one in the view the tab already shows (a new tab: the default `view/mode`), and column view sticks while
   browsing; its own sort key and order, else the default `view/sortKey`/`view/sortDescending`. Keep Folders on Top,
   Show Hidden Files and the preview pane of each view stay global (QSettings `Grassfield/Files`); each folder keeps its
   view, sort and grouping (F-3). Tag search results (F16) in the column mode show as a list.
5. F5 Sidebar: Favorites = Home, Applications, Desktop, Documents, Downloads, Pictures, Music, Videos when the folder exists
   (Applications always; Go > Applications, Ctrl+Shift+A; whether a folder exists is asked off the GUI thread, and one on a
   mount that does not answer stays listed, dimmed, until it answers, ADR-0035 4b-18); Tags (F16);
   Locations = Computer (`/`), Solid storage volumes (not ignored, filesystem usage) with mount on click and eject
   (`Solid::StorageAccess::setup/teardown`), every other filesystem udisks2 lists (the internal drives' partitions, mounted
   or not; `VolumeLogic::volumes`: no swap, EFI, boot, reserved or recovery partition, no hint-ignored or hidden one, none
   mounted on the system's own paths such as `/`, `/boot`, `/home`, `/var`), named by label else by size ("500 GB Volume"),
   mounted on click by udisks2's `Filesystem.Mount` (polkit through the session's own agent; never a format, a
   partition or a write; internal volumes have no Eject), the list kept by udisks2's ObjectManager signals, Network (`remote:/`) only when a KIO `smb` or `sftp` worker exists (its
   listing hides kio-extras' "Apple Devices" `afc:` entry, an Apple trademark in the UI, master-prompt §14:
   `FileLogic::hiddenNetworkEntry`),
   Trash (`trash:/`, full/empty icon from a KIO listing). Items accept drops.
   **Applications** (`grassfield-apps:/`, macOS: Finder's Applications): a virtual, read-only location listing the desktop
   applications the shell's Apps grid lists, by the grid's own behaviour (`ApplicationsLogic`: Quickshell 0.3.1's
   DesktopEntries as measured, `shell/launchpad/hidden-entries.sh`, `Model.disambiguate`; the header of
   `applicationslogic.h` lists the rules). Not the desktop entry specification: Quickshell does not read TryExec, so an entry
   whose program is missing is listed here as in the grid, and it reads the file as written (a CRLF file, `Name = x` and a
   `Categories` list that ends without `;` behave as in the grid). Two apps of one name are told apart as in the grid
   ("Files" and "Files (GNOME)"). `tests/shell/apps_grid_vs_files.sh` runs the real Quickshell DesktopEntries, the script
   and Model.js and the Files logic on ~130 fixture entries and requires equal lists, in English and French; localized names,
   theme icons through the same provider as the rest of Files, sorted by name. Search filters it by name. Double-click, Ctrl+O (File > Open) and
   Ctrl+Down start the application (`FilesApp::launchApplication`, the way the Apps grid starts it: the Exec line without its
   field codes, behind `xdg-terminal-exec` for Terminal=true entries, in the uwsm-app scope of a real session; Return renames
   in Finder and here, so in this read-only location it is refused like F2); Get Info shows what the desktop entry says. Nothing can be renamed, copied, moved, trashed or created in it,
   nothing can be dropped into it or dragged out of it; the refusal reads as Finder's (no permission to access some of the
   items) and the menu items are dimmed, not hidden. An absolute `Icon=` file is decoded by `appicons.h` (PNG, and SVG that
   names nothing outside itself; sizes capped; on a worker thread; see security.md GF-070); anything else shows the generic
   application icon. Known differences from the grid (symbolic link loops, the icon decoder) are listed in `applicationslogic.h`.
6. F6 Operations, all KIO jobs: copy/cut/paste (`KIO::paste`, `text/uri-list` + KDE cut flag + GNOME format),
   Move to Trash (`KIO::trash`), Put Back (`KIO::restoreFromTrash`), Delete Immediately (only in `trash:/`,
   confirmed), Empty Trash (`KIO::emptyTrash`, confirmed), New Folder (`KIO::mkdir`, "untitled folder", inline
   rename), Rename (`KIO::moveAs`, inline, F2, base name preselected), Duplicate ("name copy.ext", `KIO::copyAs`),
   drop (`KIO::move`/`copy`), undo/redo (`KIO::FileUndoManager`, Ctrl+Z / Ctrl+Shift+Z; one step per command: Rename N Items, Make Alias and New Folder with Selection are kept by Files as `BatchOps` commands, ordered against KIO's by `newCommandSerialNumber`, review of PR #98). Errors show in a banner.
   Pasting copies into the same folder makes duplicates instead of a conflict.
7. F7 Opening: folders navigate; files open with `KIO::OpenUrlJob` (MIME associations, executables never run: app
   launchers, scripts and programs are refused by Files itself before KIO, `src/launchguard.h`, GF-070, see
   `docs/specs/security.md` "Files never runs what it opens");
   Open With lists `KApplicationTrader::queryByMimeType` apps and launches with `ApplicationLauncherJob`.
8. F8 Context menus (Grassfield `PopupMenu`): item menu (Open, Open With, Open in New Tab, Move to Trash, Get Info,
   Rename, Duplicate, Glance, Copy, Cut, Show in Enclosing Folder while searching), Trash item menu
   (Put Back, Delete Immediately…, Get Info, Copy), background menu (New Folder or Empty Trash…, Get Info, Paste,
   View As, Sort By, Show Hidden Files). The toolbar Action menu offers the same items. Submenus (Open With, View As,
   Sort By) open to the left of the menu, or move up, when they would leave the window (`PopupMenu.bounds`).
9. F9 Get Info window: icon/thumbnail, name, kind, size (folders: `KIO::directorySize`), where, created, modified,
   opened, link target, owner, group, permissions, access (read only).
10. F10 Window: tabs (section "Tabs and windows": Ctrl+T, Ctrl+W, Ctrl+Shift+W, Ctrl+Alt+W, Ctrl+Tab, Ctrl+Shift+[ ],
    Ctrl+Shift+T, Ctrl+Alt+Shift+T, middle click, drag), new window (Ctrl+N), back/forward (Ctrl+[ / ],
    Alt+Left/Right, a mouse's side buttons and the XF86Back / XF86Forward keys: `HistoryButtons.qml`, over every view and the
    sidebar, in the browser window and the Open and Save panels), enclosing folder (Ctrl+Up), open (Ctrl+O, Ctrl+Down), rename (Return, F2), Go to Folder (Ctrl+Shift+G / Ctrl+L:
    `~`, paths, `trash:/`), Home (Ctrl+Shift+H), reload (Ctrl+R/F5), hidden files (Ctrl+H), search (Ctrl+F),
    context menu (Menu, Shift+F10). Path bar (clickable, drop targets) and status bar ("N items, X available",
    "K of N selected", job progress), both hidden by default (View > Show Path Bar, Show Status Bar; "Views and
    selection").
11. F11 Drag and drop: items drag out as `text/uri-list` (Drag.Automatic, works with other apps); drops on the
    background, folders, sidebar items and path segments; same filesystem moves, otherwise copies; Option (Alt) copies,
    Cmd (Ctrl) moves, Cmd+Option makes a symbolic link (`FileLogic::dropAction`, "Views and selection" Drop modifiers);
    Recents refuses every drop (no target, the drag shows it); spring-loaded folders open under a resting drag. Every view
    is a drag source (icons, list, columns, gallery strip); the column view keeps its columns until a drag that started in
    one has ended (`ColumnView.dragging`), so a spring-loaded folder never frees the column the platform drag runs in.
12. F12 Glance: Space and the menu item "Glance at “name”" call `FilesApp.glance(urls)`, which starts
    `grassfield-preview --glance -- <paths>` detached for the local regular files of the selection (folders and remote
    items are skipped, at most 50 files). The Glance window takes the focus; Space or Esc there closes it. Blocked by
    `GRASSFIELD_FILES_NO_LAUNCH=1` like every launch. A missing binary raises the usual failure banner.
13. F13 Appearance: light/dark and Reduce Motion follow `grassfield.json` (read only, watched); app windows are
    opaque; tokens only (`files.*` group of `ui/tokens/tokens.json`). Error banners use the destructive colour.
14. F14 Global menu (T1, master-prompt 5.7, ADR-0008): each browser window exports its menus through DBusMenu
    (`qml/GlobalMenu.qml`, a `Qt.labs.platform` MenuBar) while `com.canonical.AppMenu.Registrar` is on the session
    bus: `apps/globalmenu.h` watches the name (QDBusServiceWatcher) for the life of the app, creates the MenuBar when it
    appears (an app started before the bridge), destroys it when it goes away and recreates it on an owner change (a
    bridge restart); without it the bar keeps the T0 menus and the in-window controls stay usable. File (New Window,
    New Folder, New Tab, Open, Open With for the selection, Close Tab/Window, Get Info, Rename, Duplicate, Glance,
    Tags (the seven colours, checked when every selected item has one), Move to Trash or Put Back, Delete Immediately…
    and Empty Trash… in the Trash, Find), Edit (Undo, Redo, Cut, Copy, Paste, Select All), View (as
    Icons/List/Columns/Gallery, Use Groups, Group By, Sort By, Show/Hide Sidebar, Show/Hide Preview, Show Path Bar, Show
    Status Bar, Show Hidden Files, Show Previous/Next Tab, Reload), Go (Back, Forward, Enclosing Folder, Recents, the
    sidebar places without the tags, Go to Folder…). The app menu and Window are the shell's
    T0 menus. Items run the same BrowserTab actions as the window and show the window's shortcuts; a key registered
    by both a menu item and an in-window Shortcut runs once (the Shortcut also acts on `activatedAmbiguously`). An
    operation error shows in the window that was active last (a global menu action runs while the shell's menu holds
    the keyboard).
15. F15 Gallery view (`qml/GalleryView.qml`): a large preview of the current item above a horizontal strip of
    thumbnails, and the preview pane on the right ("Preview pane") shown or hidden with View > Show Preview
    (Ctrl+Shift+P, `view/galleryInfo`, on by default). The
    preview is a KIO thumbnail at `files.galleryPreviewSize` x `files.thumbnailOversample` px (at most the 1024 px
    xx-large cache size) from the same pipeline as the icon thumbnails: FolderModel runs two channels (icon size, role
    `thumbnail`; gallery size, role `largeThumbnail`), each with its LIFO request queue, 32-item PreviewJobs and an LRU
    cap (512 and 8). Each preview page asks for its thumbnail when created and drops the request when destroyed, so the
    neighbours kept around the current page are ready before the arrows reach them; until then the icon-size
    thumbnail, then the type icon, is shown (never enlarged past its pixels). The first item is selected once the
    folder is listed. Keyboard: Left/Right move along the strip, Home/End, PageUp/PageDown by the visible thumbnails
    (`Nav.stripMove`), Space opens Glance, Return renames, Ctrl+O and Ctrl+Down open, Ctrl+Up as everywhere. In the strip a click selects (Shift
    extends, Ctrl toggles), a double click opens, items drag out and folders accept drops; a right click opens the item
    menu, on the empty area the folder menu. The name under the preview is also the inline rename field (F2).
16. F16 Tags (`src/taglogic.*`, `src/tagstore.*`, `src/tagsearch.*`):
    - Storage: the extended attribute `user.xdg.tags` (freedesktop Common Extended Attributes, as Dolphin, Baloo and
      KFileMetaData write it), UTF-8, tags separated by commas, read and written with `lgetxattr`/`lsetxattr`/
      `lremovexattr` on local files and folders only; an empty value removes the attribute. Files edits the stored bytes,
      not a parsed list (`TagLogic::applyTag`): it adds one entry at the end or removes the entries of one name,
      and every other entry stays byte for byte and in order (spaces, duplicates, line breaks, invalid UTF-8). Decided
      (as macOS, which matches tag names without regard to case): a colour tag matches case-insensitively everywhere,
      so a foreign `red` is Red: the row shows it checked, one click removes it (every spelling of it, the entry the
      user removes); adding Red next to an existing `red` is a no-op; the menu, the toggle, dots, sidebar and tag search
      all use that one rule. Other tags match exactly. Nothing is written from a failed read: only ENODATA means "no
      tags"; any other error (permission, I/O, a vanished file) stops the change and shows the banner ("The tags of
      … couldn't be read/changed"), so other applications' tags are never replaced by a guess
      (`TagStore::readRawChecked`). The seven colour tags are stored under fixed English keys (Red, Orange, Yellow, Green,
      Blue, Purple, Gray: the attribute does not depend on the UI language), matched case-insensitively, shown under
      translated names (context `Tags`) in the colours of tokens `files.tagRed` … `files.tagGray`. Symbolic links are
      never followed (Linux keeps no user attributes on links; tagging a link must not tag its target).
    - Setting: the item menu ends with a colour row (PopupMenu swatch row): each colour shows whether all, some or no
      selected item has it; a click adds it to every item, or removes it when all have it. The same row is in Get Info
      (with every tag name of the item) and File > Tags in the global menu. Items that can't carry tags (not local, in
      the Trash, links, missing, FIFOs and other special files, read-only items (no write permission, read-only mount),
      on a filesystem without user extended attributes such as some network or FAT volumes) get the row disabled; the
      reason shows as the row's caption and, in Get Info, as a tooltip. Symbolic links stay untaggable on purpose: a link
      is never followed, so its target is never tagged by accident. A write that still fails (a race, a sticky folder)
      shows in the error banner with the system's reason. Get Info lists the item's tag names live, also after tagging
      from the window itself; on a read-only item the swatches still show its tags (checked, disabled) and the caption
      names the tags with the reason in brackets (the tooltip carries the reason). Files' own writes refresh every window at once.
    - Showing: coloured dots (at most `files.tagDotsMax`, overlapping) before the name in the icon view, after it in the
      list view, before the chevron in the column view and in its preview column, on the gallery strip thumbnails and
      in the preview pane (roles `tags`, `tagColors`; one attribute read per shown item, cached).
    - Sidebar Tags section: the tags in use, colour tags first (a hollow ring for a tag without a colour). "In use"
      means seen on an item Files has shown, or set in Files; the list is kept across sessions (QSettings
      `tags/known`, at most 64). Remove from Sidebar (right click) hides the tag for good, as in the macOS Finder: the
      tag stays on the files and stays usable, but it is not listed again when a folder holding it is shown (QSettings
      `tags/hidden`, at most 256). Setting that tag again from Files (colour row, drop) lists it again, and so does the
      Tags section's context menu (a right click on a tag or on the "Tags" header): "Show Hidden Tag" is a submenu of the
      removed tags (shown by name); choosing one lists it at once. A drop on a tag tags
      the dropped local items. Tags are not places of the Go menu.
    - Tag search: a click on a sidebar tag opens the location `grassfield-tag:/<tag>?in=<folder>` (Files-internal,
      never handed to KIO): the items tagged so in the folder shown at the click (a local folder; from a remote place or
      the Trash, the home folder) and below. TagSearch walks the tree on a worker thread without an index: breadth
      first, on the folder's filesystem only, never through symbolic links, hidden entries only with Show Hidden Files,
      bounded to 50,000 entries, 2,000 matches and 32 levels, cancelled when the tab navigates elsewhere or closes.
      Matches arrive in batches, each carrying its search's generation: `SearchRunner` forwards only the current one, so a
      tag or folder switch or a reload never shows the old search's matches or its end (queued signals survive a
      `disconnect`); the status bar reads "Searching…" and tells when a bound stopped the search. The
      results follow KIO's change notifications (KDirNotify: renamed, moved, removed, changed) and Files' tag writes (an
      item that loses the tag leaves, one under the folder that gets it joins). The path bar shows the folder then the
      tag; history, tabs and Back work as for folders. In the results, rename, cut, copy, Move to Trash and tags work;
      nothing can be created (New Folder, Paste, Duplicate are off); Show in Enclosing Folder opens the item's folder
      with the item selected; a drop on the results or on the tag's path segment tags the dropped items.

## Acceptance criteria
| ID | Test | Level |
|---|---|---|
| F2 sort keys (the eight of Sort By, missing values last), sizes, dates, groups (dates newest first, kind, name, size, tags, application), drop modifiers, F10 path segments, F6 names, F5 hidden Network entry | `tests/unit/files/tst_filelogic.cpp` (gtest, 27 tests, run by `scripts/dev/test.sh`) | L0 |
| F3/F10 keyboard moves (also grouped), history, type-to-select, header sort, rubber band (also grouped: list spans, icon cells with sideways scroll), grouped icon layout, column prefix; F4/F15 view modes (Ctrl+1..4, saved value fallback, tag results as a list), strip moves, initial gallery row; a drag keeps its view (`Nav.shownView`) | `tests/unit/tst_filesnav.qml` (20 cases) | L0 |
| F15 gallery on a stand-in listing: first item shown, Left/Right/Home/End along the strip, Up/Down still, Space and Return reach the tab, large previews asked for on the way, preview pane preference, the pane's Tags field; Recents refuses a drag, a strip drag is bracketed by the tab's dragStarted/dragFinished | `tests/unit/tst_filesgallery.qml` (8 cases) | L0 |
| Grouped icon view on a stand-in listing: a view made before its size makes the cells it shows, only the sections near the view are made (600 groups), Show All and reveal | `tests/unit/tst_filesgrouped.qml` (3 cases) | L0 |
| Sidebar: Eject target and menu; Recents takes no drop and does not spring; the Applications place opens its location | `tests/unit/tst_filessidebar.qml` (8 cases) | L0 |
| Preview pane quick actions: EXIF orientation table, kinds, minimal EXIF segment, little-endian tags, broken files, tags and mode kept, inode kept in place, PNG turned pixel by pixel; links, other kinds, animated PNGs and hard-linked files refused; the content decides (a JPEG named .png turns by its tag, a PNG named .bmp stays a PNG, a GIF, TIFF or WebP named .png is left byte for byte); a file over 128 MiB refused unread | `tests/unit/files/tst_imagerotate.cpp` (gtest, 13 tests) | L0 |
| Preview pane Dimensions: a FIFO and a link to /dev/zero named .png refused without being opened, a 4 GiB file read up to the budget, a header that never ends (a PBM comment running through 4 GiB) stopped by the budget, a link swapped in after the check never followed (for the file or a folder above it; at the end of the path only where openat2 answers ENOSYS or EPERM), network and FUSE mounts never looked at (links into them included), sizes by content and EXIF orientation, the reader never blocks its caller and calls nobody after its owner | `tests/unit/files/tst_imagesize.cpp` (gtest, 10 tests, sandbox under `GRASSFIELD_TEST_TMP`) | L0 |
| Key window: Get Info (opened with Ctrl+I) and Customize Folder take the keys; Ctrl+W (Escape in Get Info) closes them alone and the browser window stays with its tab, with and without the global menu; none of the browser's Shortcuts or keyed global menu items is live meanwhile, all are again after; with Get Info or Customize Folder open and the browser the key window, Ctrl+T, Ctrl+W (every press) and Escape act on the browser only. A drag keeps its view on a real tab until its handlers have returned | `tests/unit/tst_filesbrowser.qml` (9 cases: the real windows offscreen over a stand-in FilesApp) | L0 |
| Recents: the xbel parse (local files, newest first, once), broken documents, location and file, the loader (existing regular files only), renames followed; only a regular list is read, bounded and whole (a link to /dev/zero, a FIFO, a folder, over 32 MiB refused), the loader ends on them | `tests/unit/files/tst_recents.cpp` (gtest, 8 tests, sandbox under `GRASSFIELD_TEST_TMP`) | L0 |
| Applications location (FP-26): the list of what the Apps grid lists, entry ids, Copy of the entries, refusals; icon decoding in a child (PNG and SVG by their bytes, hostile SVGs refused, a big icon written in pieces is read to EOF: without the fix `TheDecoderChildReadsAnIconWrittenInPiecesToTheEnd` and `ABigIconFileGoesThroughLoadIsolated` fail, 0 of 3) | `tests/unit/files/tst_applications.cpp`, `tst_appicons.cpp`, `tst_imageproviders.cpp` (gtest); `tests/unit/tst_filesinfoapp.qml` (Get Info), `tst_filesnav.qml` (history with the location, the icon source routing), `tst_filessidebar.qml`, `tst_filesbrowser.qml` (double-click and File > Open launch, at most ten), `tst_filesglobalmenu.qml` (no Open With, no Glance), `tst_filesgrouped.qml` (no drag out of it); the launch command (`execArguments`, `launchCommand`: xdg-terminal-exec for Terminal=true), a FIFO named .desktop and a folder link to a huge tree (folder limit 5000) in `tst_applications.cpp` | L0 |
| Per-folder views (F-3) with grouping and the new sort keys; hostile files and lock paths | `tests/unit/files/tst_folderviews.cpp` (gtest, 23 tests) | L0 |
| Global menu: bar items (Path Bar, Status Bar, Sidebar, Preview), Group By follows the tab | `tests/unit/tst_filesglobalmenu.qml` (6 cases) | L0 |
| F16 tag parse/serialize, colour keys, selection states, search locations; byte-for-byte edits (`applyTag`, the reviewer's foreign value), sidebar hiding, `user.xdg.tags` write/read/remove, raw round trip, foreign tags, long values, links, FIFOs, read-only files, the probe cache, folders on files under the test sandbox (`GRASSFIELD_TEST_TMP` in `.dev/`; skipped without user xattrs) | `tests/unit/files/tst_tags.cpp` (gtest) | L0 |
| F16 a superseded search's queued batches and done never arrive (switch, stop); done once | `tests/unit/files/tst_tagsearch.cpp` (gtest, 3 tests) | L0 |
| F16 tag dots and swatch marks reach 3:1 (fill or darker edge) on the window colour | `tests/visual/test_contrast_tokens.py` | L0 |
| F16 palette from tokens, swatch models, dots cap, swatch row states, pointer, keyboard, disabled reason; PopupMenu swatch rows | `tests/unit/tst_filestags.qml` (5 cases), `tst_popupmenu.qml`, `tst_menunav.qml` | L0 |
| F6 copy/paste, F2 rename, new folder + inline rename, undo/redo, duplicate, trash + Put Back, Ctrl+W quit, no app launch, no QML errors, owner Trash untouched | `tests/apps/files_sandbox.sh` (nested compositor, own private D-Bus bus, app through `scripts/dev/isolated.sh`, refuses the owner's bus; keyboard + pointer, 19 checks) | L1 |
| F15 | `tests/apps/files_tags_shots.sh [en\|fr]`: nested screenshots of the gallery view with a thumbnail preview, the strip and the info panel; Right moves the preview (`.dev/shots/files-tags-<lang>-2-gallery.png`, `-3-gallery-next.png`) | L1 |
| F16 | `tests/apps/files_tags_shots.sh [en\|fr]` (sandbox files only): dots in the icon view and the sidebar's Tags section (`-1-icons`), the gallery panel's tags, Get Info before and after tagging from the window (caption names the tag, `-5-info`, `-6-info-tagged`), a read-only file's disabled row with its reason (`-7-info-readonly`), the tag search (`-8-tag-search`); earlier evidence: item menu colour row, a tag set (sandbox file), dots in the icon, list, column and gallery views, Get Info tag row, sidebar Tags section and a tag search listing the tagged files of the sandbox tree | L1 |
| F14 registrar | `tests/apps/files_registrar.sh` (nested, private bus, stand-in registrar `tests/apps/files_registrar_stub.py`): no menu bar before a registrar; one appears with it; destroyed when the registrar is killed (SIGKILL, like a crash) and when it exits cleanly; back with the next owner; no QML error. Observed: the menu bar object (a `created`/`destroyed` log line of the Loader) and the app's own registrar log; the DBusMenu reaching the shell's bar needs the compositor plugin and the menu bridge (covered for Preview by `tests/integration/global_menus.sh`) | L1 |
| F4/F5/F8/F9/F10/F13 | nested screenshots: icon view with thumbnails, list sorted by date, columns, Get Info, item menu, two tabs with Trash, light icon/list, search, hidden files | L1 |
| F11 | nested: drag of a file onto a folder moved it (sandbox), Ctrl+Z moved it back | L1 |
| F14 | nested, private bus with the bridge: File, Edit, View, Go in the bar; File > New Folder and Edit > Undo clicked with the pointer created and removed the folder (sandbox); Open With lists the selection's applications; `tests/integration/global_menus.sh` covers the same T1 path with Preview | L1 |
| Search (ADR-0027): location round trips, criteria on facts, saved search JSON and file names, the walk, localsearch and plocate stand-ins (root and hidden filtering, fallback, no match vs error, Contents needs the index), superseded runs, the saved searches store (0600, same name replaces), an empty smart folder asks for nothing | `tests/unit/files/tst_search.cpp` (gtest, 16 tests, sandbox under `GRASSFIELD_TEST_TMP`) | L0 |
| Search as you type: nothing before typing rests, one history entry refined in place, emptied back to the folder | `tests/unit/tst_filesbrowser.qml` (`test_searchAsYouType`) | L0 |
| Go menu (FP-75..77): Go to Folder targets and matches, a file's path opening its folder with the file selected (real files under `GRASSFIELD_TEST_TMP`), Connect to Server addresses and refusals (no password kept, no file: or trash:), recent lists, place shortcuts | `tests/unit/files/tst_navlogic.cpp` (gtest, 5 tests) | L0 |
| Rename N Items (FP-57): Replace, Add, Format (index, counter, date), checks before renaming | `tests/unit/files/tst_renamelogic.cpp` (gtest, 4 tests) | L0 |
| Compress and Expand (ADR-0029): Finder names, bsdtar argv (./names, no -P), the listing's size, a password-protected archive; real round trips with bsdtar (an @name, a folder, a link kept as a link), a hostile `../` member written nowhere outside, no temporary name left, a cancel | `tests/unit/files/tst_archive.cpp` (gtest, 5 tests, sandbox under `GRASSFIELD_TEST_TMP`; skipped without bsdtar) | L0 |
| Sharing & Permissions (ADR-0028 option 1): privileges of a mode, a change per class (folder Read is r-x, a file keeps x, special bits kept), the recursive operators, the mode text | `tests/unit/files/tst_permissionlogic.cpp` (gtest, 4 tests) | L0 |
| Decision F-6 and FP-51: no Cut in the item menu, Move Item Here in the folder's menu acts, Empty Trash never in a dev session | `tests/unit/tst_filesbrowser.qml` (`test_moveItemHereAndNoCut`) | L0 |
| Combined PR 3–5 in the headless session (sway, `scripts/dev/isolated.sh`, the test home only): a search of This Computer, the scope bar, a Kind row, Save into the sidebar, Go to Folder completion, Connect to Server, the item menu, Rename N Items, Compress, Get Info's privileges changed on a test file (644 → 604, then restored), the copy window during a 30 000-file copy | screenshots listed in the PR (not committed); visual NOT verified on the owner's compositor | L1 (headless) |
| lint | `scripts/dev/qmllint.sh` (covers `apps/**`) and `check-textformat.py` | L0 |
| F5 mount/eject, removable media | not testable without a removable device | L2 (owner) |

## Interfaces / contracts
- `grassfield.json` version 1 (read only): `appearance`, `accessibility.reduceMotion`; location like the shell
  (`GRASSFIELD_CONFIG_HOME` → `$XDG_CONFIG_HOME/grassfield` → `~/.config/grassfield`).
- `files-views.json` in the Grassfield state directory (`GRASSFIELD_STATE_HOME`, else `$XDG_STATE_HOME/grassfield`), 0600,
  written atomically: `{"version":1,"folders":[{"url":…,"mode":…,"sortKey":0-7,"descending":bool,"groupBy":0-8}, …]}`
  (`FileLogic::SortKey` and `FileLogic::GroupBy`; an out-of-range value reads as unset), the folders in the
  order they were last set (at most 2000; the first goes when full); a missing version reads as 1. It is read like
  `grassfield.json` by the shell's store: never opened unless the path leads to a regular file (a FIFO, a device, a
  directory is refused without blocking), at most 2 MiB + 1 bytes read and used only when the read returned the file's
  whole size; a change is noticed by device, inode, size, mode and modification time. A file it cannot use (not a
  regular file, over 2 MiB, unreadable, malformed, a newer version) is left exactly as it is; the views chosen meanwhile
  hold in the running Files and are written with the next choice once the file is usable again. Writes take
  `files-views.json.lock` without waiting: when another Files process holds it, the write stays pending and is tried
  again on a timer (50 ms doubling up to 5 s; a lock left by a dead process is taken over at once), and at exit Files
  waits at most 0.5 s for it (`folderviews.h`). A lock path that is not a regular file (a directory, a FIFO, a link) is
  not another Files writing: the write is refused at once without opening it, never retried by the timer, and the reason
  is logged once until a write succeeds; the choice stays pending for the next one.
- QSettings `~/.config/Grassfield/Files.conf`: `view/tabBar` (Show Tab Bar), `window/width` and `window/height` (the
  last browser window's normal size, 200-16384, ADR-0026 part 1), `view/mode` (the default view: icons|list|columns|gallery, anything else reads as icons),
  `view/sortKey` (0 name, 1 kind, 2 date modified, 3 size, 4 date created, 5 date last opened, 6 tags, 7 application),
  `view/sortDescending`, `view/foldersFirst`, `view/showHidden`, `view/galleryInfo` (default true), `view/preview` (the
  preview pane beside the icon and list views, default false), `view/columnPreview` (default true), `view/pathBar` and
  `view/statusBar` (default false), `view/sidebar` (default true), `tags/known` (the sidebar's tags, stored names in display order, at most 64),
  `tags/hidden` (tags removed from the sidebar, at most 256), `sidebar/favorites` (the folders the user added to Favorites,
  URLs in display order, at most 64) and `sidebar/hidden` (the standard places the user removed from it, by URL; F-17),
  `go/recentFolders` (Go > Recent Folders and Go to Folder's
  list: local folders and servers, newest first, at most 10), `servers/recent` and `servers/favorites` (Connect to Server:
  at most 20 each, the URL without any password, decision F-9).
- Search location `grassfield-search:/?q=<text>&in=<local folder URL>&c=<attribute>:<op>:<unit>:<value>…` (ADR-0027;
  Files-internal like a tag search: `in` absent searches This Computer, each `c` is a filter row, all percent-encoded).
- Saved searches: one JSON file per search in `$XDG_DATA_HOME/grassfield/saved-searches/` (folder 0700, files 0600,
  written atomically; ADR-0020): `{"version":1,"name":…,"scope":"computer"|<folder URL>,"query":…,"filters":[{attribute,
  op, value, unit}],"sidebar":bool}`; at most 200 files of 64 KiB are read, a file that is not version 1 JSON is left as
  it is and not listed.
- External programs, never through a shell: `localsearch search -f -l N -- <term>` and `plocate -i -b -l N -- <term>`
  (search backends, ADR-0027), `bsdtar` (Compress and Expand, ADR-0029), `xdg-terminal-exec` (New Terminal at Folder and
  terminal applications, decision F-7), `/usr/bin/chmod -R -- <ops> <folder>` (Apply to enclosed items, ADR-0028 option 1).
- Extended attribute `user.xdg.tags` (F16): UTF-8 tag names separated by commas, no escaping (a comma inside a tag
  becomes a space when Files writes it); colour tags under the keys Red, Orange, Yellow, Green, Blue, Purple, Gray.
- Tag search location `grassfield-tag:/<tag>?in=<percent-encoded folder URL>` (Files-internal: history, tabs, the
  path bar and Go to Folder; never passed to KIO).
- Recents location `grassfield-recents:/` (Files-internal, like a tag search); it reads `$XDG_DATA_HOME/recently-used.xbel`
  (`~/.local/share` without it) and never writes it (decision F-5; KIO's open jobs add the files Files opens).
- Desktop entry `org.grassfield.Files.desktop`: `Exec=grassfield-files %U`, `Icon=org.grassfield.Files` (own icon, branding/icons/apps, hicolor),
  `MimeType=inode/directory;`.
- Environment: `GRASSFIELD_FILES_QML` (dev QML dir), `GRASSFIELD_FILES_NO_LAUNCH=1` (scripted tests: opening
  reports an error instead of starting apps, logged), `QT_LOGGING_RULES="grassfield.files.debug=true"` (listing
  times, selection and expectation traces).
- Glance: `FilesApp.glance(QList<QUrl>)` runs `grassfield-preview --glance -- <paths>`; the program is
  `GRASSFIELD_PREVIEW_CMD` (dev, may carry arguments), else `grassfield-preview` next to the Files binary, else the PATH.

## Dependencies (verified 2026-10-17)
Qt 6.11.2 (Core, Gui, Widgets, Qml, Quick), KDE Frameworks 6.29 (KIOCore, KIOGui, KIOWidgets, CoreAddons, Service,
Solid), gtest (tests only). No new package. Build: `apps/files/build-direct.sh` (g++, parallel units, explicit
`/usr/include/KF6/*`, `KF_DISABLE_DEPRECATED_BEFORE_AND_AT=0x061D00`); `CMakeLists.txt` for when cmake/ECM are
installed (not built here).

## Degraded behavior
- No thumbnailer for a type: the theme icon for the MIME type.
- No udisks2/Solid backend: only Computer under Locations.
- No KIO network worker: no Network entry.
- No job-tracker service (kuiserver): progress shows in the status bar (jobs run with `HideProgressInfo`).
- Compositor plugin absent (nested dev): no titlebar; the window still works (title in the toolbar).
- Icon theme missing a name: generic MIME icon, then `text-x-generic` / `folder`.
- LocalSend (`localsend`) or `systemd-run` not on PATH: no Share button in the toolbar and no Share… in the item menu (looked up when
  a window opens or becomes active and when a menu is built); a send that cannot start says so in the window's banner.

## Automated tests · Manual verification steps
- `scripts/dev/test.sh` (gtest + QML), `scripts/dev/qmllint.sh`, `tests/apps/files_sandbox.sh [output]` (needs
  `scripts/dev/nested-up.sh` and `apps/files/build-direct.sh`; all files under `.dev/files-sandbox`; the app runs
  through `scripts/dev/isolated.sh` with its XDG homes in `.dev/isolated/files-sandbox`, so the Trash is a sandbox
  Trash, on a private dbus-daemon started by the script with the same homes and the nested Wayland socket, so KIO's
  D-Bus-activated helpers (kiod6, kpasswdserver6, kioexecd6) never run with the owner's environment; the script
  refuses to run on the owner's session bus and stops the app's and the bus's process groups on exit).
- Tags on real files: only under `.dev/` (the gtests use `GRASSFIELD_TEST_TMP`; nested evidence tags sandbox files).
- Manual (L2, owner): plug a USB stick (mount on click, eject), open a text file and an image with the default app,
  drag files to and from another app, Empty Trash on a test item.

## Performance (gates affected) · Accessibility · i18n
- Nested, 2000 empty files: listing completes in 0.6–1.0 s (cold); RSS ≈164 MB idle, 171–181 MB with the folder
  listed and scrolled (baseline with a 2-item folder ≈166 MB); wheel scrolling through the icon and list views:
  103/102 frames, render median 15 ms, max 16–17 ms (≥ 99 % under 16.7 ms), polish ≤ 1 ms
  (`QSG_RENDER_TIMING`). Not measured on the reference hardware (L2).
- Thumbnails are requested by created delegates and cancelled when the delegate is destroyed (a request not yet
  started is dropped); the newest request is served first (LIFO, `previewqueue.h`), jobs hold at most 32 items,
  and at most 512 thumbnails are kept (oldest evicted, re-requested when shown again). Measured with 2000 PDFs:
  the visible page after End is thumbnailed in ~0.3 s; paging through the whole folder generated ~140 thumbnails.
- The lister uses delayed MIME types: the Kind sort uses the extension/name guess (memoized) until an item's type is
  known, and rows a view displays refine their type from content once (never the whole folder on the GUI thread).
  Kind sort of 2000 extension-less files: 529 ms (was ~3100 ms).
- Tags cost one `lgetxattr` per shown item (cached per URL; 8-17 us each measured, so a screenful costs about 1 ms);
  filtering never reads them, and sorting or grouping reads them only by Tags (one read per item, the same cache; not
  measured on a large folder). The menus ask the tag state of the whole selection on every selection change:
  measured with 1000 selected files, 41 ms (untagged) and 66 ms (tagged) per change before; now one probe pass
  (lstat, access, one lgetxattr per file, 19-28 ms) the first time and 2-3 ms from the 3 s cache (`TagStore::Cache`,
  dropped for the files Files writes; another application's change shows on the next lookup (one `lstat`, the ctime moves; two changes inside one kernel clock tick may be missed until the 3 s expire); a write always reads afresh). The tag search runs
  off the GUI thread (one `readdir` per folder, one `lgetxattr` per entry, one `lstat` per subfolder) and hands
  matches over in batches (64 items or 100 ms). Gallery previews: at most 8 gallery-size thumbnails are kept (up to
  4 MB each at 1024 px). Not measured on the reference hardware (L2).
- Per-folder view settings (`files-views.json`, F-3): opening a folder costs one `stat` of the store when nothing changed;
  the load is linear (68,000 short entries in a 2 MiB file: about 0.2 s, `FolderViews.ManyShortEntriesLoadInLinearTime`;
  it was 41 s). A view or sort choice writes the whole store on the UI thread (serialised, synced, renamed) and reads
  it again first only when another process changed it; the bound is the 2 MiB limit: about 50 ms per choice at the
  limit (`FolderViews.OldFoldersMakeRoomUnderTheSizeLimit`, 50 choices in 2.6 s on the dev machine, was 7.9 s), a few ms
  for a store of a few hundred folders. A store reaches the limit only with about 2000 folders of 1 KB paths.
- Names with line breaks show on one line with `⏎` in place of each break (display only).
- Accessibility: `Accessible.role/name` on every control, list item, header, banner and dialog; full keyboard
  operation; untrusted text (file names, KIO messages) is `Text.PlainText`.
- i18n: every visible string is `qsTr()` / `tr()`; plurals use singular/plural pairs (no catalogs with numerus forms).

## Names, Unicode and case (GF-105)
- Grassfield Files follows the file system: Linux is case-sensitive, so `Report.txt` and `report.txt` are two items and renaming `a` to `A` is a real rename (macOS's default volume is case-insensitive; the Sort and the folder filter ignore case, collisions do not).
- Names that differ only by Unicode normalization (NFC "e acute" and NFD "e" + combining accent) are the same name to a person, like on macOS: the folder filter folds case and accents in both forms (`FileLogic::nameMatchesFilter`), and rename, new folder, duplicate, copy, move and drop refuse to create a second entry that is an NFC/NFD twin of an existing one (`FileLogic::sameName`, `equivalentName`; an exact match is left to the conflict handling of the file operation). The file system keeps both forms apart; Files never renames an existing file to normalise it.
- Every file name shown (views, titles, Info, menus, messages, Preview, desktop icons, Dock stacks) goes through `DisplayName.text` (QML) or `FileLogic::displayName` (C++): line breaks become the return symbol and the bidi override, embedding and isolate controls (U+202A-U+202E, U+2066-U+2069) are written out as `<U+202E>`, as Finder shows them; the marks LRM and RLM stay. `tests/shell/display_names.sh` fails when a view shows a raw name (`raw-name-ok` marks one that is never shown).

## Known limitations (honest, user-visible gaps vs macOS)
- Thumbnails come from KIO's thumbnail plugins (kio-extras, installed 2026-10-17: images, PDF, video); a type without
  a plugin keeps its MIME icon. The Network place (kio-extras smb/sftp workers) lists MTP devices and SMB shares; the
  "Apple Devices" entry is hidden (§14).
- Sharing is LocalSend only (Share > Send with LocalSend…, ADR-0045 OC-13): no Mail, Messages or nearby-device sheet of
  Grassfield's own. LocalSend opens its own window to pick the device; the receiving device must be running LocalSend
  (and reachable on the local network: Omarchy's firewall opens LocalSend's port 53317 on this machine). Only local files
  and folders can be sent (not the Trash, Applications, a server's items or a search of a server). Not in the File menu
  (macOS has Share… there too). The send was not run in the cloud session that built it (no LocalSend there).
- Search (ADR-0027) finds names through localsearch, then plocate, then a bounded walk of the home folder
  (200 000 items, 2000 results, 32 levels); contents only where localsearch indexed them; results do not update live
  (a file created while they are shown appears at the next search). The Open and Save panels still filter their folder
  (F-14). Recents lists what `recently-used.xbel` holds (files
  opened by applications that write it), not every file opened; a recent file renamed while no Recents view is open
  leaves it (the list keeps the old path). Group By has no Date Added (no such time on Linux files); the grouped layouts
  have no reference capture (visual NOT verified).
- Tags: colour tags from the menus and named tags from Tags… (tags of other applications are shown in Get Info and the
  gallery panel, kept, searchable from the sidebar and droppable onto). Tag changes are
  not part of Undo. The sidebar lists the tags seen in use, not an index of the disk: a tag no longer used stays until
  Remove from Sidebar. The tag search walks one folder tree with bounds (no global search, no live query: an item
  tagged by another application while the results are open appears after Reload). A tag written by another
  application shows once the folder is listed again (KIO's refresh does not always report attribute changes).
  Symbolic links, items in the Trash, remote items and filesystems without user extended attributes cannot be tagged
  (the row says why). Copies keep their tags (KIO copies extended attributes); a copy made by another tool may not.
- Preview pane: no Markup (Grassfield has no annotation editor); rotation covers JPEG, PNG and BMP only and is not part
  of Undo; the gallery's preview changes in place without the macOS slide.
- Space does not close a Glance from Files by itself; the Glance window has the focus and closes on Space/Esc.
- KIO's questions are Grassfield sheets since ADR-0035 step 4a (docs/specs/system-dialogs.md section 9): file-exists
  conflicts, skips, certificates, a worker's messages; a document with no application gets a notice until the Choose
  Application sheet of ADR-0035 D-5; Undo keeps a copy changed since it was made and says so. Paste takes items only
  (text or an image on the clipboard is not pasted, as the Finder).
- Terminal applications (for example `nvim.desktop`, the default for text files here) fail to open: KIO starts them
  through `kdeglobals` `[General] TerminalApplication` (default konsole, not installed on Omarchy). Observed in a
  nested run as the banner "Terminal konsole not found…". Workaround: set `TerminalApplication` (owner config).
- Open With lists the registered applications only (no "Other…" chooser, no "change default").
- Mount, eject and removable media are implemented with Solid but not exercised (only ignored internal volumes here).
- Empty Trash and Delete Immediately are implemented with confirmations but were never run by tests (the real Trash is
  never emptied); Put Back cannot be undone (KIO keeps no undo record for restores).
- The global menu has no Help menu (there is no help content) and no Window menu of its own: tab switching is under
  View, the window actions are the shell's T0 Window menu. Info windows export no menu (the bar shows T0 there).
- Window position: a Wayland client cannot place its window, so a new window (New Window, a dragged-out tab) opens
  where the compositor puts it, today exactly over the previous one (centred); the size is remembered. Position memory and
  cascading belong to the compositor's placement rules (ADR-0026 part 2, not done: it needs the nested session).
- View Options (Cmd+J) do not exist yet, so the defaults cannot be changed: the view and sort of folders without their own
  are `view/mode`, `view/sortKey`, `view/sortDescending` as written before PR 1 (else icons by name), and a choice made
  in a folder is that folder's only (F-3). "Use as Defaults" comes with View Options, which PR 2 moved to later (FP-47,
  FP-86, open).
- A tab dragged out and dropped while the pointer is outside every Files window becomes a window, also when the drag was
  cancelled there with Esc (the platform reports a cancel and a drop nobody took the same way).
- Reopen Closed Tab remembers the tabs closed in this session only (not across launches), at most 10.
- Spring-loaded folders: Space does not open the folder at once (Qt's platform drag takes the keys). Drop modifiers
  follow the Finder with Cmd as Ctrl; Cmd+Option makes a symbolic link, which, unlike an alias, does not follow a moved
  original.
- The path bar shows home-relative paths inside home, otherwise from `/` ("Computer"); long paths are clipped on the left.
- The sidebar shows "Trash full" only if the icon theme has `user-trash-full-symbolic`.
- Accessibility tree not verified with a screen reader (no AT-SPI bus in the nested session).
- French catalog: `translations/grassfield_fr.ts` (gate I1, `just check-i18n`).

- Combined PR 3–5: an alias is a symbolic link (it breaks when the original moves; Make Alias is undoable, one step per command: see the undo note below);
  Get Info changes only one's own items (ADR-0028's administrator path is not built); Open with has no per-document
  choice (Linux associates applications with types: the pop-up stages Change All…); Connect to Server's password dialog is
  kiod's (F-9); Compress makes zip only and Expand asks for no password (ADR-0029); the copy window shows no amounts for a
  paste (KIO::PasteJob forwards none); Empty Trash is never run by an automated test (KIO's empty-trash job empties every
  volume's trash).

## Finder parity matrix (step 0, 2026-10-26)

Owner goal (2026-10-26): Grassfield Files is the macOS 27 Finder on Linux: same layout, behaviours, shortcuts and finish,
with the power of Linux shown the macOS way, never as a "Linux-style" extra interface. This matrix lists every Finder
function, what Files does today (main c687708), the reference capture, the Linux backend (KIO first) and what cannot be
done. It starts from "Known limitations" above; each later PR updates its rows and the limitations. UI target: F1 strict
(ADR-0024): no visible difference on a careful look, outside the accepted limits by name (Inter for SF Pro, own symbols,
no lensing before phase 4, 1x displays, own colours). Geometry ±1 pt (±0.5 pt on a 2x source), tints ±0.1, hover,
selection and keyboard focus measured, A2 in both appearances.

**State**: **done** (behaves like the Finder), **partial** (exists, differs), **missing**, **n/a** (no meaning on this system).
**PR**: 1 windows and tabs, 2 views and selection, 3 search, 4 Linux power, 5 finish and debts, "later" (not in the five
PRs, kept here so the list is complete), "never" (impossible or excluded, with the reason).

**References** (512 Pixels "Aqua Screenshot Library", macOS 27 Golden Gate release, 2 px per pt, listed in
`docs/audits/ui-finesse-2026-10-25/tools/webref-urls.txt` and the library index; downloaded into the git-ignored
`design/reference/macos27/`, never committed; only numbers measured on them enter the repository). Short names below are
the file names without the `27-Golden-Gate-` prefix: Finder-Home, Finder-Menu, Go-Menu, Finder-Gallery, Finder-Search,
Finder-Get-Info, Finder-Network (column view), Finder-Go-To-Folder, Finder-Connect-to-Server, Finder-Replace (conflict),
Finder-Copy (progress), Finder-Customize, Finder-Empty-Trash, Finder-Eject-Warning, Finder-Quick-Look,
Finder-Quick-Look-Markup, Applications, Applications-Utilities. "none": the library has no capture of it; the behaviour
comes from the macOS 26/27 Finder, the geometry from the macOS 26 guides in `design/reference/macos/` when the owner's
copy is present, otherwise the row says "visual NOT verified" in its PR.

**Command key.** As today (BrowserWindow.qml, `config/hypr/grassfield/forwarding.lua`): ⌘ is Ctrl, ⌥ is Alt, ⇧ is Shift,
⌃ is Super. A chord the compositor binds (`bindings.lua`) is reached through the forwarded form (⌘1…⌘4 and ⌘↑/⌘↓ are
sent by Super). Menus show the device's style (`keyboard.shortcutStyle`: symbols on a Mac keyboard, key names on a PC).
Every new chord is checked against `bindings.lua` and `forwarding.lua` in its PR.

### Windows and tabs
| # | Finder function | Files today | Reference | Linux backend | Impossible / limit | PR |
|---|---|---|---|---|---|---|
| FP-1 | New Finder Window ⌘N | done (PR 1: opens at the home folder, at the kept size) | Finder-Home | — | a new window opens over the previous one: placement is the compositor's (ADR-0026) | 1 |
| FP-2 | New Tab ⌘T; the tab bar appears with the second tab | done (PR 1: at the new-window location, last) | none | — | — | 1 |
| FP-3 | View > Show/Hide Tab Bar ⇧⌘T (bar shown with one tab) | done (PR 1) | none | — | — | 1 |
| FP-4 | Tab bar look (equal-width tabs, close × on hover, + at the end, selected tab) | done (PR 1, measured on the AppKit tab bar of a macOS 26 capture; hover not measured) | none (visual NOT verified until a capture is supplied) | — | — | 1 |
| FP-5 | Close Tab ⌘W, Close Window ⇧⌘W, Close All ⌥⌘W | done (PR 1) | Finder-Menu (File) | — | — | 1 |
| FP-6 | Show Previous/Next Tab ⇧⌘[ ⇧⌘], ⌃⇥ ⌃⇧⇥ | done | none | — | — | 1 |
| FP-7 | Window > Move Tab to New Window | done (PR 1, in View: F-10) | none | — | — | 1 |
| FP-8 | Window > Merge All Windows | done (PR 1, in View: F-10) | none | — | — | 1 |
| FP-9 | Drag a tab out of the window → new window; drag tabs to reorder; drop a tab on another window's tab bar | done (PR 1) | none | Qt drag with an app-internal MIME type | the new window's position is the compositor's (ADR-0026) | 1 |
| FP-10 | Drop files on a tab: copy or move into its folder; hovering a tab during a drag switches to it (spring-loaded) | done (PR 1) | none | KIO copy/move (`FilesApp.drop`) | — | 1 |
| FP-11 | Reopen the last closed tab | done (PR 1, this session's tabs) | none (no Finder item; Safari's ⇧⌘T) | in-app stack | ⇧⌘T is Finder's Show Tab Bar, so File > Reopen Closed Tab takes ⌥⇧⌘T (decision F-2) | 1 |
| FP-12 | ⌘-double-click a folder opens it in a new tab; Open in New Tab in the menu | done (PR 1) | none | — | — | 1 |
| FP-13 | The window remembers its size and position; new windows cascade | partial (PR 1: the size; position and cascade wait for ADR-0026 part 2) | none | size: Files (QSettings); position and cascade: compositor `placement.lua` (ADR-0026) | a Wayland client cannot place its own window | 1 (size), compositor lane (position) |
| FP-14 | Each folder remembers its view settings (view, sort, grouping, icon size; View Options "Always open in…", "Use as Defaults") | partial (PR 1: view and sort per folder; PR 2: grouping; View Options later, FP-47; the defaults cannot be changed until then: FP-86) | none | per-user store keyed by URL (decision F-3) | macOS keeps them in `.DS_Store` inside the folder; Files writes nothing into folders | 1 (view, sort), 2 (grouping), later (View Options) |
| FP-15 | Window menu: Minimize ⌘M, Zoom, Fill, Center, Move & Resize, Full Screen, Cycle Through Windows ⌘\`, Bring All to Front, window list | partial: the shell's T0 Window menu (menubar.md); the tab items in View (PR 1) | Finder-Menu | compositor | the window list and tab items of Finder's Window menu need the app's own Window menu: Move Tab to New Window and Merge All Windows go into the exported View menu until then (decision F-10) | 1 |
| FP-16 | Windows and tabs restored at the next launch | missing | none | QSettings | — | later |

### Toolbar, sidebar and chrome
| # | Finder function | Files today | Reference | Linux backend | Impossible / limit | PR |
|---|---|---|---|---|---|---|
| FP-17 | Back/forward capsule, title, ••• Action menu, search circle | done (lot 5, F1 match) | Finder-Home | — | — | — |
| FP-18 | View switcher group (4 views; a single view popup ⌃ when the window is narrow) | done (PR 2: measured, 161 x 36; the pop-up while searching or where the title has no room) | Finder-Home, Finder-Search | — | — | 2 |
| FP-19 | Group By toolbar button (grid ⌃) | done (PR 2) | Finder-Home | FolderModel sections | — | 2 |
| FP-20 | Share button | done (ADR-0045 OC-13): a bare glyph before Tags while LocalSend is installed; its menu, which the item menu's Share… after Copy opens where that menu was (macOS 13 and later), starts with "Send with LocalSend…" (where macOS puts AirDrop) | Finder-Home | LocalSend (Omarchy's `omarchy-menu-share` invocation) | no Mail, Messages or other services; no Share… in the File menu | — |
| FP-21 | Tags toolbar button (tag the selection) | done (combined PR 3–5): the colour tags and Tags… from the toolbar button; glyph measured on Finder-Search (18 pt) | Finder-Home | `user.xdg.tags` (F16) | — | 5 |
| FP-22 | Search field expands to the full width while searching | done (combined PR 3–5): the field takes the toolbar's free width while a search is shown, the title keeping its room | Finder-Gallery, Finder-Search | — | — | 3 |
| FP-23 | View > Hide/Show Toolbar ⌥⌘T, Sidebar ⌃⌘S, Path Bar ⌥⌘P, Status Bar ⌘/ (path and status bars hidden by default) | done (PR 2) except Hide Toolbar (the toolbar holds the window controls when the sidebar is hidden) | Finder-Home (no bars), Finder-Search (path bar) | QSettings | — | 2 |
| FP-24 | View > Customize Toolbar… | missing | none | — | — | later |
| FP-25 | Title menu: ⌘-click or right-click on the title lists the enclosing folders | done (PR 1) | none | `pathSegments` | — | 1 |
| FP-26 | Sidebar macOS 27: Recents at the top without a header; Favorites (Applications, Desktop, Documents, Downloads); Locations (the home folder by user name, the system disk, volumes, Network, Trash); Tags | done: Recents at the top without a header (PR 2); Favorites lists Home, Applications (the virtual `grassfield-apps:/` location), Desktop, Documents, Downloads, Pictures, Music, Videos; Locations has Computer, volumes, Network, Trash | Finder-Home, Finder-Gallery | KIO places, Solid | iCloud Drive, Shared and AirDrop: no equivalent (never) | 2 |
| FP-27 | Sidebar editing: drag a folder in to add it, Remove from Sidebar, reorder, Add to Sidebar ⌃⌘T; collapse a section on hover; Settings > Sidebar choices | partial (owner report 2026-11-07, decision F-17): Add to Sidebar ⌃⌘T (Ctrl+Super+T) in File and a folder's item menu, folders dragged between Favorites rows (insertion line), a folder of the user's moved or dragged out, Remove from Sidebar on every Favorites folder place (right click, the Menu key); tags: Remove from Sidebar, Show Hidden Tag. Not done: collapsing a section, Settings > Sidebar, files and apps in the sidebar | none | QSettings `sidebar/favorites`, `sidebar/hidden` (decision F-17) | — | owner fix |
| FP-28 | Sidebar icons in the accent colour, neutral selection with a bold label | done (lot 2) | Finder-Home | — | — | — |
| FP-29 | Eject button on volumes, Eject ⌘E | done, never exercised | Finder-Eject-Warning | Solid `StorageAccess::teardown` | — | 5 (tests) |
| FP-30 | Folder banner ("Folder shared with File Sharing") | n/a | Finder-Home | — | no File Sharing state to show | never |
| FP-31 | Finder Settings ⌘, (new windows show, open folders in tabs, sidebar items, show all extensions, warn before emptying the Trash, remove items from the Trash after 30 days, keep folders on top, default search scope) | missing (some exist as menu toggles) | Finder-Menu | QSettings; KIO trash `ktrashrc` limits | the app menu is the shell's T0 menu: Settings… needs a menubar change (decision F-10) | later |

### Views and selection
| # | Finder function | Files today | Reference | Linux backend | Impossible / limit | PR |
|---|---|---|---|---|---|---|
| FP-32 | Icon view with thumbnails, selection backdrop and name pill | done | Finder-Home | KIO thumbnails | — | — |
| FP-33 | List view: Name, Date Modified, Size, Kind; relative dates; sortable headers | done | none | — | — | — |
| FP-34 | List view: disclosure triangles (expand folders in place, ⌘→ ⌘←), resizable and reorderable columns, more columns (Date Created, Last Opened, Date Added, Tags, Comments) | missing (PR 2 moved it: a tree model under the sorted, grouped listing is its own change) | none | KDirModel children; KFileItem times | Date Added: no such time on Linux files (never; shown for the Trash's deletion date only) | later |
| FP-35 | Column view with a preview column; resizable columns | partial: the preview column (PR 2); fixed widths (moved: no reference for the column handles) | Finder-Network | — | — | later (resizing) |
| FP-36 | Gallery view with the strip and an info panel | done (F15) | Finder-Gallery | — | — | — |
| FP-37 | Preview pane in every view, View > Show Preview ⇧⌘P (name, kind, size, Information with Show More, Tags) | done (PR 2) | Finder-Gallery | — | — | 2 |
| FP-38 | Quick actions in the pane: Rotate Left, Markup, More… | partial (PR 2): Rotate Left, More… > Rotate Right; no Markup | Finder-Gallery | JPEG: the EXIF orientation tag; PNG, BMP: Qt image I/O, lossless | Markup: no annotation editor (preview.md non-goals); WebP, HEIF, GIF, TIFF: no lossless turn here, no action | 2 |
| FP-39 | Group By (None, Name, Kind, Application, Date Last Opened, Date Added, Date Modified, Date Created, Size, Tags) and Use Groups ⌃⌘0 | done (PR 2) except Date Added | Finder-Home (button) | FolderModel sections | Date Added: see FP-34 | 2 |
| FP-40 | Sort By (Name, Kind, Date Last Opened, Date Added, Date Modified, Date Created, Size, Tags) within groups | done (PR 2, with Application) except Date Added | none | KFileItem times, tags | — | 2 |
| FP-41 | Rubber band (lasso) selection in every view | done (PR 2: icon, grouped icon, list and column views; the gallery has none, as in the Finder) | none | — | — | 2 |
| FP-42 | Spring-loaded folders during a drag (hover opens, Space opens at once) | done (PR 2) except Space | none | — | — | 2 |
| FP-43 | Return renames, ⌘O and ⌘↓ open | done (PR 2; F2 renames too) | none | — | — | 2 |
| FP-44 | Type-to-select | done | — | — | — | — |
| FP-45 | Quick Look: Space, ⌘Y, ⌥Space full screen, arrows walk the selection | partial: Space and ⌘Y (PR 2) start Glance (Preview) | Finder-Quick-Look, Finder-Quick-Look-Markup | `grassfield-preview --glance` | — | 2 (⌘Y), Preview spec (the rest) |
| FP-46 | Recents (Go ⇧⌘F, sidebar) | done (PR 2) | Finder-Home, Go-Menu | `$XDG_DATA_HOME/recently-used.xbel` (decision F-5) | KIO's `recentlyused:/` needs the activity manager daemon, absent on Omarchy | 2 |
| FP-47 | View Options ⌘J (always open in, browse in, group/sort, icon size, grid spacing, text size, label position, show item info, show icon preview, calculate all sizes, list columns, Use as Defaults) | missing (PR 2 moved it: no reference capture of the panel, and most of its options need FP-34's columns) | none | per-folder store (F-3) | — | later |
| FP-86 | View Options "Use as Defaults": the shown folder's view and arrangement become those of every folder without its own | missing, **open since PR 1**: since a view or sort chosen in a folder is that folder's (F-3), nothing changes the defaults (`view/mode`, `view/sortKey`, `view/sortDescending` keep the values written before PR 1, else icons by name); the Finder sets them only with this button, so no menu item stands in for it (opus review of PR #5) | none | QSettings `view/*` | — | later (with FP-47) |
| FP-48 | Icon view free arrangement, Clean Up, Clean Up By, Snap to Grid | missing: always a sorted grid | none | — | free positions need a per-folder position store; not planned | later |

### File operations
| # | Finder function | Files today | Reference | Linux backend | Impossible / limit | PR |
|---|---|---|---|---|---|---|
| FP-49 | Copy, Paste, Undo/Redo, Select All | done | — | KIO, FileUndoManager | — | — |
| FP-50 | Move: Copy then ⌥⌘V (Move Item Here); no Cut for files | done (combined PR 3–5): no Cut for files, Edit > Move Item Here ⌥⌘V; a cut made in another file manager still pastes as a move | none | `KIO::paste` | decision F-6 | 5 |
| FP-51 | Move to Trash ⌘⌫, Put Back, Empty Trash ⇧⌘⌫ with the confirmation | done (combined PR 3–5): ⇧⌘⌫ from any folder, confirmed, never in a dev session; never run by tests (KIO empties the trash of every mounted volume, the owner's too) | Finder-Empty-Trash | KIO trash | — | 5 |
| FP-52 | Delete Immediately ⌥⌘⌫ on any item (confirmed) | done (combined PR 3–5): ⌥⌘⌫ on any item, confirmed | none | `KIO::del` | — | 5 |
| FP-53 | Duplicate ⌘D | done | — | `KIO::copyAs` | — | — |
| FP-54 | Make Alias ⌃⌘A ("name alias"); ⌥⌘-drag makes an alias | done (combined PR 3–5): ⌃⌘A makes "name alias", a symbolic link to the item's absolute path; one Undo step for all the aliases of the command (review of PR #98) | none | symbolic link (`BatchOps`, no name ever replaced) | a macOS alias survives moves; a symbolic link does not | 4 |
| FP-55 | Show Original ⌘R | done (combined PR 3–5): ⌘R on an alias selects its original (⌘R reloads otherwise; F5 always) | none | KFileItem link target | — | 4 |
| FP-56 | Inline rename | done (Return, F2) | — | `KIO::moveAs` | — | 2 |
| FP-57 | Rename multiple items (Replace Text, Add Text, Format with index, counter or date) | done (combined PR 3–5): Replace Text, Add Text, Format with an example; checked before anything is renamed (RenameLogic, and every target on the disk); local items: all renamed or none (a failure part-way puts back what was done), ONE Undo step (review of PR #98); items on a server: one KIO job each, neither all-or-nothing nor one step | none | `BatchOps` (`renameat2` without replace) for local items, `KIO::moveAs` per item for a server | a server's batch is not atomic | 4 |
| FP-58 | New Folder ⇧⌘N; New Folder with Selection ⌃⌘N | done (combined PR 3–5): ⌃⌘N moves the items into "New Folder With Items", renamed in place; a local folder: made and moved together or not at all, ONE Undo step (review of PR #98); a server's folder: two KIO jobs, two steps | none | `BatchOps` (local), `KIO::mkdir` + move (server) | a server's folder keeps two undo steps | 4 |
| FP-59 | Compress (zip) and Expand (double-click an archive) | done (combined PR 3–5): ADR-0029; opening an archive expands it next to itself | none | `bsdtar` (libarchive) out of process (ADR-0029) | — | 4 |
| FP-60 | Get Info ⌘I: General, More Info, Name & Extension, Comments, Open with + Change All…, Preview, Sharing & Permissions | partial (combined PR 3–5): General, tags, Customize Folder, Open with + Change All…, Sharing & Permissions editable for one's own items; Comments, Name & Extension, Preview: missing | Finder-Get-Info | KIO stat, `KIO::chmod`, `KIO::chown` | Locked: no user-level lock flag (`chattr +i` needs root, never); Stationery pad: n/a | 4 (permissions), 5 (Open with) |
| FP-61 | Sharing & Permissions editable, the padlock for items you do not own | partial (combined PR 3–5): one's own items (owner, group, everyone, the group's pop-up, Apply to enclosed items…); the padlock stays closed for other items until the owner's pkexec check and the opus review of ADR-0028's privileged path. The table keeps the window's one content margin; the Privilege and group cells are inline pop-ups (text and the up-down disc, no bezel). Known limit (follow-up: a small pop-up size for table cells, as Finder's): in French, beside "Lecture et écriture", the group pop-up has only a few letters at the 264-pt window (F1 gap 17), "ale…" for "alexandra" on screen, and its text is the menu size, larger than the name labels; English shows short names in full | Finder-Get-Info | unprivileged: `KIO::chmod`/`KIO::chown`; privileged: ADR-0028 (polkit) | — | 4 |
| FP-62 | Inspector ⌥⌘I (one Info window that follows the selection) | missing | none | — | — | later |
| FP-63 | Tags… editor: named tags, Add Tags field in Info and the preview pane | done (combined PR 3–5): Tags… adds and removes named tags (a colour's name gives the colour tag); the preview pane's field (PR 2); Info keeps the colour row | Finder-Gallery, Finder-Get-Info | `user.xdg.tags` | — | 5 |
| FP-64 | Copy as Pathname ⌥⌘C | done (combined PR 3–5): ⌥⌘C, one path per line | none | clipboard | — | 4 |
| FP-65 | Open With: the list, Other…, Change All… | done (combined PR 3–5): Other… (the Choose Application panel, ADR-0035), Change All… in Get Info (mimeapps.list) | Finder-Get-Info | KApplicationTrader, `mimeapps.list` | — | 5 |
| FP-66 | Drag modifiers: ⌥ copies, ⌘ moves, ⌥⌘ makes an alias | done (PR 2) | none | `FilesApp.drop` | ⌘ is Ctrl: Ctrl-drag moves, Alt-drag copies, Ctrl+Alt makes a link (PR 2) | 2 |
| FP-67 | File-exists sheet: Keep Both / Stop / Replace, Apply to All | done (ADR-0035 step 4a): Keep Both / Skip / Stop / Replace, Merge for folders, Apply to All | Finder-Replace | KIO `AskUserActionInterface` (ADR-0022) | — | 5 |
| FP-68 | Copy progress window (name, bar, "41.9 MB of 111.6 MB – About 10 seconds", ×) | done (combined PR 3–5): the copy window (measured on Finder-Copy) with the bar, amounts, time left and a stop button; a paste follows the copy or move KIO's PasteJob runs inside (`FilesApp::forwardSubjobAmounts`), so it shows amounts too; the title names the items asked for and the folder they go to ("Copying 12 items to “Docs”", `FileLogic::copyTitle`), the line says "Preparing…" and the bar sweeps while KIO has no total (it is looking through the folders to copy) | Finder-Copy | KJob speed and size signals | the progress pie on the destination icon: later | 5 |
| FP-69 | Print ⌘P | missing | none | the default application's print | — | later |
| FP-70 | Show Package Contents, Burn to Disc | n/a | — | — | no bundles or optical burning in scope | never |

### Search
| # | Finder function | Files today | Reference | Linux backend | Impossible / limit | PR |
|---|---|---|---|---|---|---|
| FP-71 | Find ⌘F; title "Searching “This Mac”"; scope bar This Mac / "folder" (Grassfield says "This Computer", F-12) | done (combined PR 3–5): ⌘F searches This Computer as one types (250 ms), "Searching “This Computer”", the scope bar measured on Finder-Search; the Open and Save panels still filter their folder | Finder-Search | ADR-0027 | — | 3 |
| FP-72 | Filters: Kind, Last opened, Last modified, Created, Name, Contents, Size, Tags (the + rows) | done (combined PR 3–5): the + rows (attribute, condition, value, unit; − removes); Contents only through localsearch, said in the status bar without it | Finder-Search (+) | ADR-0027 | contents only where localsearch indexed them, or a bounded scan of the folder | 3 |
| FP-72b | The field's suggestion tokens: typing offers "Name matches", "Contents matches", Kind and date suggestions that become capsule tokens inside the field | **gap, recorded (review of PR #98)**: the same filters are all there as the + rows of the scope bar (FP-72), reached with one click and no typed syntax; the typed text is matched against names (and contents through localsearch) | Finder-Search (suggestion list) | the criteria of ADR-0027 (`SearchLogic`) | a token field is a new control of the shared UI (the field's text, the tokens, a suggestion pop-up, keyboard and VoiceOver model for deleting a token), well over the size of this PR and not verifiable here without a nested visual pass; the engine needs nothing new (a token is a criterion row) | later (own PR with `SearchField` tokens) |
| FP-73 | Saved searches (Save, a smart folder in the sidebar), New Smart Folder ⌥⌘N | done (combined PR 3–5): Save (name, Add To Sidebar; one place, so no Where pop-up), saved searches in Favorites (Remove from Sidebar, Move to Trash: the file goes to the Trash, as the Finder does for a smart folder), File > New Smart Folder ⌥⌘N | Finder-Search (Save) | JSON saved searches (ADR-0027) | — | 3 |
| FP-74 | The path bar shows the selected result's path | done (combined PR 3–5): the path bar shows itself while searching, with the selected result's path (nothing without a selection) | Finder-Search | — | — | 3 |

### Go menu and Linux power, the macOS way
| # | Finder function | Files today | Reference | Linux backend | Impossible / limit | PR |
|---|---|---|---|---|---|---|
| FP-75 | Go menu places with Finder's shortcuts (Recents ⇧⌘F, Documents ⇧⌘O, Desktop ⇧⌘D, Downloads ⌥⌘L, Home ⇧⌘H, Computer ⇧⌘C, Network ⇧⌘K, Applications ⇧⌘A, Utilities ⇧⌘U), Recent Folders | done (combined PR 3–5): Documents ⇧⌘O, Desktop ⇧⌘D, Downloads ⌥⌘L, Computer ⇧⌘C, Network ⇧⌘K, Recent Folders (10, Clear Menu); Utilities ⇧⌘U: never (the Applications location has no category folders) | Go-Menu | — | AirDrop ⇧⌘R, iCloud ⇧⌘I, Shared ⇧⌘S: never | 4 |
| FP-76 | Go to Folder ⇧⌘G: inline completion and a "Go to:" list of matching paths | done (combined PR 3–5): the panel measured on Finder-Go-To-Folder, inline completion (Tab, →), the Go to: list listed off the GUI thread, the recent folders while empty; Return opens the typed folder itself when it exists ("/" and "~/" open the root and the home folder, not their first subfolder) and completes only a partial path (an arrow key's choice is kept); a file's path opens its folder with the file selected (as the Finder); completion of local folders only (a URL is typed whole) | Finder-Go-To-Folder | `KUrlCompletion`-like listing (own, async) | — | 4 |
| FP-77 | Connect to Server ⌘K: address field with history, Favorite Servers (+, −), Browse, Connect | done (combined PR 3–5): its own window measured on Finder-Connect-to-Server (address and history, Favorite Servers + −, Browse, Connect); no ? button (no help book) | Finder-Connect-to-Server | KIO `smb`, `sftp` (kio-extras), `ftp`, `webdav(s)` (KIO) | the password prompt is kiod's own dialog (decision F-9); other applications see the share through kio-fuse when installed, otherwise KIO hands them a temporary copy | 4 |
| FP-78 | Show hidden files ⇧⌘. | done (combined PR 3–5): ⇧⌘. (Ctrl+H stays) | none | KDirLister | — | 4 |
| FP-79 | Services > New Terminal at Folder | done (combined PR 3–5): the context menu's Services > New Terminal at Folder | Finder-Menu (Services) | `xdg-terminal-exec` (decision F-7) | the app menu's Services submenu is the shell's (F-10): the item sits in the context menu's Services submenu | 4 |
| FP-80 | Terminal applications open (Open With nvim) | done (combined PR 3–5): Terminal=true applications run behind xdg-terminal-exec | none | `xdg-terminal-exec` (F-7) | — | 5 |
| FP-81 | KIO's widget dialogs replaced by Grassfield sheets: file exists, Open With chooser, undo confirmation | done (ADR-0035 step 4a) but the Open With chooser (a notice until ADR-0035 D-5) | Finder-Replace | `AskUserActionInterface`, `OpenWithHandlerInterface`, `FileUndoManager::UiInterface` | kiod's password dialog stays (F-9) | 5 |
| FP-82 | Network browsing | partial: `remote:/` (smb, sftp) | Finder-Network | kio-extras, avahi | SMB discovery needs wsdd or avahi on the network | 4 |

### Desktop, accessibility and look
| # | Finder function | Files today | Reference | Linux backend | Impossible / limit | PR |
|---|---|---|---|---|---|---|
| FP-83 | Desktop items, stacks | shell desktop module (desktop.md) | Finder-Desktop-Stacks | — | outside this matrix | — |
| FP-84 | VoiceOver | Accessible roles and names set | — | AT-SPI | screen reader not verified (no AT-SPI bus in nested) | later |
| FP-85 | Window corner, shadow, traffic lights | compositor (C-1, C-3) and grassfield-ui (ADR-0015) | Finder-Home | Hyprland, plugin | — | — |

### Decisions (integrator, owner delegation D-5; macOS model first)
- **F-1 Command key**: the mapping above; Finder's ⌃⌘ chords become Ctrl+Super chords when `bindings.lua` leaves them free
  (⌃⌘A, ⌃⌘N, ⌃⌘S, ⌃⌘0 are free on main c687708).
- **F-2 Tabs**: ⇧⌘T shows or hides the tab bar (Finder). Reopen Closed Tab (no Finder equivalent, asked by the owner) is
  in the File menu with ⌥⇧⌘T; it reopens the location, history and view of the last tabs closed in this session (at most
  10, newest first).
- **F-3 Per-folder view settings**: a per-user store (`$XDG_STATE_HOME/grassfield/files-views.json`, 0600, at most 2000
  folders, least recently used dropped), keyed by the cleaned URL, holding the view, sort key and order, grouping and
  View Options; a folder without an entry uses the defaults (View Options "Use as Defaults"). Files never writes into the
  folder (macOS's `.DS_Store`, KDE's `.directory`): it works on read-only, remote and Trash locations alike, and other
  applications never see stray files. A tag search or saved search keeps its own entry. The file joins ADR-0020's table
  of Grassfield's files with the code that writes it (PR 1, #5).
- **F-4 Return renames** (macOS), ⌘O and ⌘↓ open; F2 keeps renaming (PC keyboards).
- **F-5 Recents**: the files listed in `recently-used.xbel` (written by GTK and KDE applications and read by the shell's
  Search and Recent Items), newest first, existing local files only, at most 500; Files adds the files it opens there
  through KIO (KRecentDocument).
- **F-6 Move**: Finder has no Cut for files. Edit shows Copy and, while ⌥ is held, Paste becomes Move Item Here ⌥⌘V.
  A cut made in another file manager still pastes as a move (interop: the clipboard says so; Files shows the move in the
  paste's progress). **Amended by F-18** (owner request 2026-11-07): Files has Cut ⌘X as well.
- **F-7 Terminal**: the session's terminal is `xdg-terminal-exec` (Omarchy; the shell uses it for `Terminal=true` entries,
  ADR-0011). Files starts terminal applications and "New Terminal at Folder" through it, never through KIO's konsole
  lookup; the working directory is the folder. Launches keep `launchguard.cpp`'s rules (Files never runs a program from a
  folder; the terminal itself is an application the user chose).
- **F-8 Archives**: Compress makes a `.zip` (Finder's Archive Utility default) and Expand reads zip, tar, tar.gz, tar.bz2,
  tar.xz, tar.zst and 7z with `bsdtar` in a child process (ADR-0029).
- **F-9 Connect to Server**: Files asks for nothing itself; KIO's worker asks kiod's password server, whose dialog is KDE's
  (a QWidget). Restyling it needs a replacement of the password server (a new service): not done; listed as a limit.
  Recent and favourite servers are stored in Files' QSettings (no password ever).
- **F-10 App menu and Window menu**: the app menu (About, Settings…, Empty Trash…, Services, Hide) and the Window menu are
  the shell's T0 menus (menubar.md). Items only Files can run (Empty Trash, Merge All Windows, Move Tab to New Window,
  Services) are exported in Files' own menus (File, View) and context menus until the menu bar can host app-provided app
  and Window items (a menubar change, later).
- **F-11 Bars**: the path and status bars are hidden by default, as in the Finder; View shows them. The status bar
  carries job progress and notices (a search stopped early) until the progress window exists (FP-68, PR 5): from PR 2
  to PR 5 it shows itself while a job runs or a notice is up, whatever the setting, so nothing is hidden; FP-68 then
  takes the progress. Combined PR 3–5: the copy window takes KIO's jobs; the status bar still shows itself for a notice and
  while Compress or Expand runs (bsdtar's jobs are no KIO jobs).
- **F-13 Show Original and reload** (combined PR 3–5): ⌘R is the Finder's Show Original when one alias is selected; with
  anything else it reloads the folder, as before, and F5 always reloads (the PC habit).
- **F-14 Search scope** (combined PR 3–5): typing in a browser window's field searches This Computer (the Finder's
  default), a search location in the tab's history refined in place; the Open and Save panels keep filtering the shown
  folder by name (a panel picks in one folder; a search in it later).
- **F-12 Names**: no Apple trademark in the UI (master-prompt §14): "This Mac" is "This Computer" (« Cet ordinateur »), as
  in the system menu's About This Computer; Quick Look is Glance; Archive Utility has no name of its own (Files expands).
- **F-15 Names in menus** (owner report 2026-11-07, "the context menu grows too wide when the file name is long"): an
  item's name inside a menu label (Compress “name”, Glance at “name”, Copy “name”) is drawn shortened in its
  middle to `menu.nameMaxWidth` (160 pt), its start, its extension and the words around it kept, as the Finder truncates long
  names in its menus; the menu keeps its usual width whatever the name (a short name: 255 pt, a 90-character one: 332 pt
  instead of `menu.maxWidth` 400). The shared `PopupMenu` row takes the name (`name`, MenuItem), so Files' item, Action and
  panel menus and the desktop's item menu share it, and the accessible name keeps the whole name; the global menu's labels
  are shortened by Files before they are sent (`BrowserWindow.menuName`). Copy as Pathname became Copy's Option (Alt)
  alternate in the item menu, as in the Finder (its label was the widest row); Edit > Copy as Pathname and ⌥⌘C stay.
  Tests: `tst_popupmenu.qml` (`test_aLongNameIsShortenedInTheMiddleAndTheMenuKeepsItsWidth`, `test_aLongLabelStopsTheMenuAtItsCap`),
  `tst_filesglobalmenu.qml`, `tst_iconmenu.qml`, `tst_filesbrowser.qml`.
- **F-16 Column view selection** (owner report 2026-11-07, "sometimes it goes back to the previous folder"): a column
  selects the folder its next column shows through `FolderModel.expectAlone` (one wish per listing, replaced by the next
  one, dropped by an empty URL and by any selection made in the listing), never `expect()`, whose calls build one selection
  for a drop's items: a column still listing never brings the previous folder back over the user's choice. A click that
  leaves the location as it is no longer leaves the view's "I navigated" flag set for the next location set elsewhere. A
  right click on a row of a column selects it and the next column follows, as a click does, before the menu opens.
- **F-17 Favorites editing** (owner report 2026-11-07, "there is no way to pin a folder in the sidebar Favorites, neither
  with right-click nor by drag and drop"): the Finder's model. Add to Sidebar (File menu and a folder's item menu, ⌃⌘T as
  Ctrl+Super+T, free in `bindings.lua`) adds the selected folders, or the shown folder when nothing is selected; folders
  dragged to the top or bottom quarter of a Favorites row are added where the accent insertion line shows (the middle of a
  place still moves or copies the items into it); a folder of the user's is dragged to another gap (moved) or out of the
  sidebar (removed; the folder itself is never touched); Remove from Sidebar is in the menu of every Favorites folder place
  (right click, the Menu key or Shift+F10 on the keyboard row), with Open in New Tab. The user's folders are listed after
  the standard places, in their order (the standard places keep theirs: they cannot be reordered); a removed standard place
  (Home, Applications, a user folder) is hidden and comes back with Add to Sidebar of that folder. Only folders join
  (KIO says which items are, never a read on the GUI thread; a file is refused with "Only folders can be added to the
  sidebar."); Files' own lists (searches, tags, Recents) and the Locations places are never Favorites folders. A folder
  that is gone or does not answer stays listed, dimmed (asked off the GUI thread with the standard folders, DiskProbe).
  Kept in Files' QSettings (`sidebar/favorites`, `sidebar/hidden`), which the Open and Save panels read too, rather than in
  KDE's `user-places.xbel`, which holds KDE's own default places and would bring them into the sidebar. An Open or Save
  panel's sidebar shows the folders but edits nothing. Tests: `tst_navlogic.cpp` (SidebarFavorites), `tst_folderchooser.cpp`
  (SidebarFavorites, on KIO), `tst_filessidebar.qml` (menu, insertion line and drop, move and drag out, a panel edits
  nothing), `tst_filesbrowser.qml` (`test_addToSidebar`).
- **F-18 Cut** (owner request 2026-11-07, "there is no Cut in Files", which wins over the Finder here): Cut ⌘X (Ctrl+X) in
  Edit, in the item menu before Copy ("Cut “name”", "Cut N Items") and on the keyboard, where items can be edited (a
  writable folder or a tag search; not the Trash, the Applications location or an Open or Save panel). The cut items are
  drawn faded, as hidden ones, in every view until Paste ⌘V moves them into the folder (KIO's paste: undo, the conflict
  sheets, the Copy window's progress); the clipboard is then emptied. Esc in a view cancels a cut not pasted yet (the
  clipboard is emptied, the items no longer fade), before it clears the selection; a new Copy replaces it. The clipboard
  says "cut" the KDE way (`application/x-kde-cutselection`) and the GNOME way (`x-special/gnome-copied-files` starting with
  "cut"), so Dolphin, Nautilus and the others move what Files cut, and Files moves (and fades) what they cut. The Finder's
  own way stays: after Copy, Paste is Move Item Here while Alt (Option) is held in the folder's menu (Ctrl+Alt+V; Edit >
  Move Item Here in the menu bar, which has no Option items). Tests: `tst_folderchooser.cpp` (CutAndPaste, on KIO: Cut
  fades and Paste moves, a GNOME cut too, Copy and Esc cancel), `tst_filelogic.cpp` (the GNOME list), `tst_filescolumns.qml`
  (a cut item is faded), `tst_filesbrowser.qml` (`test_cutAndMoveItemHere`).

### ADRs opened by this step
- ADR-0026 Files window frames: size by Files, position and cascade by the compositor (cross-module: Files and
  `config/hypr`).
- ADR-0027 Files search: backends and saved searches (cross-module: the shell's Search uses the same backends).
- ADR-0028 Privileged ownership and permission changes in Files through polkit (privileged action; opus review before
  any code).
- ADR-0029 Archives through `bsdtar` in a child process (a runtime dependency of the package; untrusted input).

### Not decided here
- Toolbar customization (FP-24), sidebar editing (FP-27), Finder Settings (FP-31), the Inspector (FP-62) and window
  restoration (FP-16) are outside the five PRs; they stay listed so the matrix is complete.

## Tabs and windows (Finder model)
PR 1 of the Finder parity brief (matrix rows FP-1 to FP-16, FP-25; ADR-0026).
- **Reference.** The library has no Finder tab capture. The Finder draws the AppKit tab bar, measured on a macOS 26 (Tahoe
  beta 3) Terminal capture published by 9to5Mac (2 px per pt: the 28-px lights are 14 pt; kept in the git-ignored
  `design/reference/web/`): a capsule track 27.5 tall right under the title row, 8 from the left edge, black at 0.13 on
  the white window (222/255); the selected tab a pill 2 inside the track, white at 0.76 over it (247; the 253 edge beside it
  reads as JPEG ringing, so no rim is drawn); equal-width tabs; titles about 11 pt, secondary colour for the others; a round 28-pt + button 4.5 after the
  track and 8 from the right edge; a hairline 8 under the track. No dark capture: the dark track and pill use the
  material fill (white at 0.14). Tokens `files.tab*`, `files.springDelay`.
- **Tab bar** (`qml/TabBar.qml`, pure logic `qml/TabsLogic.js`): shown from the second tab, or with one tab while View >
  Show Tab Bar is on (Ctrl+Shift+T, `view/tabBar`; disabled with more than one tab, as in the Finder). Equal-width tabs,
  the current one the pill, titles in the caption size (current: text colour, others: secondary text, kept at A2's 4.5:1
  where the capture's lighter grey is about 3.1:1), a close button on the hovered tab (middle click closes too), a right
  click offers Close Tab, Close Other Tabs and Move Tab to New Window, and the round + opens a tab at the new-window
  location. The hairline under the toolbar shows whenever the bar does.
- **New windows and tabs** open at `FilesApp.newWindowUrl`, the home folder (Finder's "New Finder windows show"; its
  default, Recents, arrives with PR 2). Open in New Tab and Cmd-double-click on a folder open that folder in a new tab.
  New tabs go last.
- **Closing**: Ctrl+W closes the tab (the window with its last tab), Ctrl+Shift+W the window with all its tabs (File >
  Close Window, shown while there are tabs), Ctrl+Alt+W every window (File > Close All, shown with more than one window).
  Closed tabs (also those of a closed window) go on a stack of 10 for File > Reopen Closed Tab (Ctrl+Alt+Shift+T, decision
  F-2): it brings back the location, the history (Back/Forward) and the view. Ctrl+W closes the key window only: typed
  in Get Info or Customize Folder (the browser window's own windows, its transient children) it closes that window, and
  the browser stays. While one of them is the key window none of the browser's keys is live, neither its Shortcuts nor
  its global menu's keyed items (`BrowserWindow.childIsKey`); while the browser is the key window, Get Info and Customize
  Folder take none of its keys (Escape and Ctrl+W there are live only while that window is the key window). Qt reports a
  window and its transient children active together, and the shortcut matcher of QtQuick.Templates (loaded with
  Grassfield.Ui's controls) matches all their keys on that ground, so the key window is read from
  `FilesApp.focusWindow` (`QGuiApplication::focusWindow`), never from `active`.
- **Moving tabs** (Main.qml): View > Move Tab to New Window (and the tab menu) gives the current tab a window of its own;
  View > Merge All Windows brings every other window's tabs into this one, window by window, and closes the emptied
  windows (both are in View because the Window menu is the shell's, decision F-10). A tab keeps its state when it moves
  (location, history, view, selection, scroll position): the tab object itself changes window (`FilesApp.reparent` makes
  the new window its owner, and tabs are created from the application's context, not their window's).
- **Dragging a tab** (a platform drag of `application/x-grassfield-files-tab`, "<pid>:<tab id>"; a tab of another Files
  process is refused): along its own bar the other tabs slide to open the slot under the pointer (motion token
  `motionFast`) and the drop reorders; over another window's tab bar a slot opens there and the drop moves the tab there
  (an emptied window closes); anywhere else over another window it joins that window last; over its own window outside the
  bar nothing happens; dropped outside every Files window it becomes a window (a window's only tab stays). The drag image
  is the tab itself. The platform drag runs a nested event loop inside the source tab's mouse handler and the drop arrives
  inside it, so a drop is only recorded (`Main.qml` `draggedTab`): the tab moves, and an emptied source window closes,
  once the drag has ended and its handlers have returned (`Qt.callLater` from the drag's end; a target window closed
  meanwhile is not used). A torn-off tab's window opens the same way.
- **Files dropped on a tab** are moved or copied into its folder like a drop on a folder (FilesApp.drop: same file system
  moves, else copies); the source application is told "copy" (as at every drop point of Files), so it never deletes its
  files while Files still copies them. A tab hovered for `files.springDelay` (500 ms) during a file drag comes to the
  front, so the drop can also land in its view. Search results take no drop.
- **Title menu**: a right click or Cmd-click on the window title lists the enclosing folders, the shown one first; a plain
  press still moves the window.
- **Window size** (ADR-0026 part 1): the size of the last browser window resized (in its normal state, not zoomed or full
  screen) or closed is kept (`window/width`, `window/height`) and every new window opens at it.
- Tests: `tests/unit/tst_filestabs.qml` (bar visibility, close index, slots while reordering, for an incoming and an
  outgoing tab, moves, the closed-tab stack, the drag payload, a file drop on a tab and every file drop answering Copy,
  tab drops and tear-offs applied after the drag with `Main.qml` and stand-in windows, a real tab bar's drag reporting its
  start to the manager before the platform drag runs), `tst_filesbrowser.qml` (the real windows: Ctrl+W in Get Info or
  Customize Folder closes that window alone, the browser's keys wait meanwhile), `tst_filesnav.qml` (view and sort of a folder),
  `tst_filescolumns.qml` (a real column view: a double-click opens a file, a folder only with Cmd), `tst_filesglobalmenu.qml` (Reopen Closed Tab, Show/Hide Tab Bar,
  Merge All Windows, Close Window, Sort By from the tab), `tests/unit/files/tst_folderviews.cpp` (keys, invalid fields,
  merge, round trip and order, the oldest goes when full, an unreadable or newer file is never overwritten, a missing
  version, another process's entries kept; hostile files: a FIFO, a symlink to a device, one byte over the limit,
  malformed and newer files with the choice waiting, 0600 under umask 000, a stale and a taken lock, a lock path that is a
  directory, a FIFO or a link refused at once, four processes
  writing at once, 68,000 entries under a time budget, changes that keep the mtime). Headless run of the real app (sway,
  virtual keyboard and pointer, DBusMenu calls): `docs/audits/finder-parity-2026-10-26.md` § PR 1. The tab drag between
  two windows after the deferral is verified in the nested session by the integrator (not here).

## Preview pane
PR 2 of the Finder parity brief (matrix rows FP-37, FP-38). Reference: Finder-Gallery (macOS 27, 2 px per pt).
- **Measured** (pt): the pane 250 wide on the right, its own fill (235/255, the sidebar fill), no dividing line; content 11 from
  both edges and 16.5 under the toolbar; in the gallery a 42-wide preview beside the name (the name 65 from the edge, about
  15 bold, two lines), the kind and size under it (secondary); 24 to "Information" (13 bold) with Show More at the right in
  the accent colour; rows every 22.75 (label secondary at the left, value at the right), a hairline between rows; 31 to
  "Tags"; at the bottom a 70-high bar on the window background with the quick actions in three equal columns, glyphs 14
  tall at 16.5, labels 10.5 under them. Tokens `files.preview*`.
- **Where it shows** (View > Show Preview, Shift+Cmd+P; each view keeps its own setting as in the Finder): beside the icon
  and list views with a large preview at the top (`view/preview`, off by default), in the gallery with the small preview
  (`view/galleryInfo`, on), as the column view's last column on the window background (`view/columnPreview`, on). It
  shows the selected item; with nothing selected the folder; with several items their number. A hidden pane is not made
  at all, and a shown one reads the item again only when the shown or a selected row changes.
- **Information**: Created, Modified, Dimensions (pictures: read from the file's header, turned by its EXIF orientation);
  Show More adds Last opened, Size in bytes (zero and one spelt out) and Where.
- **Dimensions are never read on the GUI thread** (`FolderModel::dimensionsAt`, `src/imagesize.h`): an item's type comes
  from its name, so a FIFO named `pipe.png` or a link to `/dev/zero` named `x.png` is "a picture" to KIO, and opening it
  would never return. The row is asked only when the listing says a local regular file of an image type; a worker thread
  (one per listing, started when there is work) then walks the path from the root against the mount table before each
  `lstat` (local, removable and memory filesystems only: a network share, FUSE or a pseudo filesystem is never looked at,
  links into them included), opens only a regular file by the path the walk reached (`O_NONBLOCK`; no link followed
  anywhere in it, openat2 `RESOLVE_NO_SYMLINKS`, so a link swapped in after the walk for the file or a folder above it is
  refused wherever it leads; `O_NOFOLLOW` on the last component where openat2 answers ENOSYS, a kernel without it, or
  EPERM, a sandbox's seccomp filter; the same inode checked on the descriptor), reads the format from the content and
  at most 16 MiB. The answer arrives as the row's `dataChanged` and the pane reads it then; answers are kept per path
  for the listed time and size (at most 256). A listing destroyed during a read waits 150 ms for it, then abandons it.
- **Quick actions** (pictures Files can turn without a loss: JPEG, PNG, BMP; `imagerotate.h`): Rotate Left, and More…
  with Rotate Right; none for a selection of more than 100 items (each is looked at on disk as the selection changes).
  The name's type only offers the action; what is done is decided by the content (`ImageRotate::methodForContent`): a
  JPEG turns through its tag whatever it is called, a real PNG or BMP is written again in that same format (Qt's reading
  of the content must agree), anything else (a GIF, TIFF or WebP named `.png`) is left byte for byte. A file over 128 MiB
  (`kMaxFileSize`: it is held in memory whole, decoded and encoded again) is refused before it is read.
  The files are read and written on a thread of their own, one batch at a time and in order; Files waits for the batch
  running when it quits. Each file is opened once without following links (`O_NOFOLLOW`) and handled through that
  descriptor. A JPEG turns through its EXIF orientation tag, changed in place (two bytes, then `fsync`), or a minimal
  EXIF segment holding only the orientation when it has none; PNG and BMP are decoded, turned and written again in their
  own lossless format through a new file renamed over the old one, keeping its group, permissions, user extended
  attributes (tags) and ACLs (a folder's default ACL is not taken), synced before the rename. A rewrite is refused, and
  the file left as it is, when it would harm it: an animated PNG, a file owned by someone else or with other names (hard
  links), one whose group, tags, ACLs or other attributes cannot be kept, a picture whose own orientation tag would no
  longer match, a file renamed, replaced or changed while it was being turned. WebP, HEIF, GIF and TIFF get no quick action (a lossy
  re-encode, a lost animation, or TIFF's compression and tags, which Qt does not write back, are never risked). Markup is
  not offered: Grassfield has no annotation editor (`docs/specs/preview.md` non-goals). A turn is not part of Undo.
- Tests: `tests/unit/files/tst_imagerotate.cpp` (the EXIF table, the kinds, the minimal segment, little-endian tags,
  broken files, a JPEG without EXIF keeps its tags and mode and leaves no temporary file, an in-place change keeps the
  inode, a PNG turned pixel by pixel, links, other kinds, animated PNGs and hard-linked files refused; misnamed pictures
  by their content; the size limit), `tests/unit/files/tst_imagesize.cpp` (Dimensions: special files, a huge file, a
  header that never ends, a link swapped in after the check for the file or a folder above it, remote and FUSE mounts,
  the worker).

## Views and selection
PR 2 of the Finder parity brief (matrix rows FP-18, FP-19, FP-23, FP-39 to FP-43, FP-45, FP-46, FP-66). References:
Finder-Home and Finder-Search (toolbar), the macOS
27 Finder's behaviour where the library has no capture (grouped layouts: visual NOT verified).
- **Sort By** (View, the background menu, the Group By button; per folder, F-3): Name, Kind, Application, Date Last
  Opened, Date Modified, Date Created, Size, Tags. Date Added has no source on Linux files and is not offered. Date Last
  Opened is the file system's access time (coarse under `relatime`, absent under `noatime`); Date Created is the birth
  time where the file system keeps one (statx), else unknown. Items without the key's value (no tag, no default
  application, an unknown date) come last in both directions; ties go by name. `FileLogic::SortKey`, `compareEntries`.
- **Group By** (View > Use Groups, Ctrl+Cmd+0, and Group By; the toolbar's Group By button; per folder): None, Name,
  Kind, Application, Date Last Opened, Date Modified, Date Created, Size, Tags. The rows are sorted group by group (the
  groups in their own order whatever the direction), then by Sort By. Groups (`FileLogic::groupOf`): Name by first letter
  (accents folded, "#" for digits and symbols, first); Kind by category from the MIME type and its ancestors (Applications,
  Archives, Documents, Folders, Images, Movies, Music, PDF Documents, Presentations, Spreadsheets, then Other); Application
  by the default application's name (folders first, Other last); dates newest first (Today, Yesterday, Previous 7 Days,
  Previous 30 Days, the months of this year, the years before; Unknown last); Size largest first (More than 1 GB, 100 MB
  to 1 GB, 1 MB to 100 MB, 100 KB to 1 MB, Less than 100 KB, Zero bytes; folders last); Tags by the first tag (colours in
  palette order, then the others; No Tags last). Shown in the icon and list views; the column view and the gallery do
  not group. The list view puts a header row above each group (`files.listGroupHeight`, estimate). The icon view shows
  each group as one row under its header, scrolled sideways by a horizontal wheel or swipe; Show All lays the group out in
  full, Show Less returns it to one row (`files.iconGroupHeight`, estimate). Keyboard: Left/Right walk the items across
  groups, Up/Down move a line or to the nearest item of the next group (`Nav.groupedIconMove`); the view scrolls as
  little as it takes to show the item (down the page, then along its line; a first line comes with its header). The
  sections are placed from the group sizes (`Nav.groupedIconTops`, `groupedIconCell`, `groupedIconCells`), so the band and
  the keyboard menu work from the same numbers; a section keeps its cells and its sideways scroll while the folder
  changes or is sorted again, and only the cells near the view are made (a group of thousands shown in full included).
  A section far from the view is an empty item of its height: its header, the DelegateModel of its rows and its views are
  made while it is near the view (and the view has a cell width), so a folder grouped by name into thousands of first
  letters does not pay one DelegateModel per group on every change of the listing. Measured offscreen (software scene
  graph, 5,000 items, `tests/unit/tst_filesgrouped.qml` checks the behaviour): 2,500 groups made in 7.5 s and 4.7 ms per
  changed row before, 1.1 s and 0.3 ms now; 27 groups of 185 made 1,908 cells (4.6 s) when the view was made before it
  had its size, 168 cells (0.4 s) now; the flat grid of the same folder 0.5 s. Not measured nested or on the reference
  hardware (L2). An
  icon cell takes drops on its icon and name, like clicks; elsewhere a drop goes to the shown folder. Groups are cached
  per item and dropped item by item when an item changes, goes or is renamed (KDirModel reports each type it finds); at
  midnight (or the first grouping after it) the date groups are made again.
- **Group By button** (FP-19, measured on Finder-Home at 2 px/pt): a 46.5 x 36 capsule after the view switcher, the
  groups glyph (two rules over three 5-pt squares, 18 x 17.5, rules 1.5, outlines 1) 8 from its left end and a chevron;
  its menu lists Group By, then Sort By. Disabled in the column view and the gallery. Tokens `files.group*`.
- **View switcher** (FP-18, measured on Finder-Home at 2 px/pt): a 161 x 36 capsule of four segments 39.5 apart (1.5
  from its ends); the selected view a 34 x 28 pill darker than the capsule (the fill colour at 0.09: 230 on the
  reference's 252), a 1 x 20 rule between two views that are not selected (the fill colour at 0.22); outlined glyphs
  (strokes 1.5): icons four 7-pt squares 1 apart, list three bullets of 2 with lines 13 x 1.25 every 5, columns a
  19.5 x 15 frame in three panes, gallery a 19 x 10.5 frame over five 2.75 x 2.5 cells. While the search field is open
  (Finder-Search), or where the whole switcher would leave the title less than its room (`files.toolbarTitleMinWidth`,
  estimate), it is one 46 x 36 pop-up button: the current view's glyph 10.5 from its left end, up and down chevrons, and
  View As as its menu. Tokens `files.view*`.
- **Rubber band** (FP-41): icon view (also grouped; from any point outside an item's icon and name, between icons
  included: an icon cell takes clicks on its icon and name only), list view (from the empty space or a row outside its
  icon and name; a click there selects the row), column view (from a column's empty space; the columns after it follow
  the new selection). Shift or Cmd add to the selection. The gallery has none (as in the Finder). A band whose press is
  taken ends there; so does a list band started on a row when that row scrolls out of the cached rows (about 20 rows
  away) while it runs.
- **Spring-loaded folders** (FP-42): a drag resting on a folder of the icon, list or column view, or on a sidebar place,
  opens it in the tab after `files.springDelay`. When a drag Files started ends without a drop (released outside the
  windows, cancelled), the tab goes back to where it was; a drop or the user's own navigation keeps it. A drag from
  another application springs too; when it leaves the window (or is cancelled over it) the window's tabs go back, and a
  drop on the window keeps them where they are, whichever view took it (`FilesApp.outsideDragEnded`). The folder opened under a resting pointer becomes the drop target at once
  (`FilesApp.refreshDrag` sends the last drag move again), so a release without moving drops into it. Space does not open
  at once: Qt's platform drag takes every key press. While a drag Files started from a view runs, the tab keeps that view
  (`BrowserTab.dragView`, `Nav.shownView`): a folder sprung open in another view of its own (or a search ending) shows in
  the dragging view until the drag ends, then in its own. Qt Quick's drag uses the item that started it after its nested
  event loop returns, so destroying the view under it would be a use-after-free (`tst_filesnav.qml` for the choice,
  `tst_filesbrowser.qml` on a real tab).
- **Drop modifiers** (FP-66, ⌘ as Ctrl, `FileLogic::dropAction`): a plain drop moves within a volume and copies across
  volumes, Option (Alt) copies, Cmd (Ctrl) moves, Cmd+Option makes a symbolic link in the target (`KIO::link`, part of
  Undo). Drags offer copy and move only: Wayland's drag and drop has no link action, so Files makes the link itself.
- **Recents** (FP-46, decision F-5): first in the sidebar without a header, Go > Recents (Shift+Cmd+F); the local
  regular files listed in `recently-used.xbel`, newest first, at most 500, read on a thread of their own and again when
  the file changes (watched with its folder, a burst read once). Sorted by Date Last Opened, newest first, until arranged
  otherwise; the time is the latest the list records for the file. The list is read only when it is a regular file of at
  most 32 MiB, bounded and to its end (`Recents::readList`: a FIFO, a device or a link to one is never opened). Read only:
  a drop there is refused (the background, its path segment and its sidebar row take no drag, as in the Finder). A recent file
  renamed or moved while a Recents view is open keeps its place under the new path (`Recents::noteRenamed`, for the
  session; an entry used after the rename is the new file at the old path); to the Trash it leaves the list.
- **Glance and Redo**: Cmd+Y opens Glance like Space (Finder's Quick Look shortcut); Redo is Shift+Cmd+Z only, as in
  the Finder (Ctrl+Y was a second Redo).
- **Bars** (FP-23, decision F-11): View > Show Path Bar (Alt+Cmd+P), Show Status Bar (Cmd+/), Hide Sidebar (Ctrl+Cmd+S, the
  lights move into the toolbar); `view/pathBar`, `view/statusBar` (off), `view/sidebar` (on). Until Files has a progress
  window (FP-68) the status bar also shows while a job runs or a notice is up. Hide Toolbar is not offered: the toolbar
  holds the window controls when the sidebar is hidden.
- **Return and Cmd+O** (FP-43, decision F-4): Return renames the selected item, Cmd+O and Cmd+Down open.
- The list view keeps its column widths and scrolls sideways (the header with it) when it is narrower than its columns
  (a narrow window, the preview pane).

## Folder colours and Customize Folder (owner request 2026-10-19; macOS 26 model)
macOS 26 colours folders (System Settings > Appearance > Folder Color: the accent or a colour) and "Customize Folder…" gives one folder its own colour and an optional symbol or emoji drawn on it; a folder follows the global colour until it has its own. Grassfield copies that model.
- **Global**: `icons.folderColor` (`theme` = the icon theme's own folder colour, the default; `accent`; `#rrggbb`), Settings > Appearance > Folder colour (Theme, Accent, eight swatches). Applies live to every folder icon Grassfield draws: Files (icon, list, column and gallery views, the column preview, Get Info) and the desktop. Dock stacks and Search folder results do not exist today (the Dock has apps, minimized windows and the Trash; Search file rows use one generic document icon), so there is nothing to colour there; when they appear they use `FolderIcon`.
- **Per folder**: context menu "Customize Folder…" (fr « Personnaliser le dossier… »; also File menu, and a button in Get Info), a window with a live preview, Colour (Default = follow the global colour, Accent, the seven tag colours, or a typed `#rrggbb`), Symbol (30 suggestions, or any typed or pasted emoji or symbol; the field holds one grapheme cluster at all times, so the preview is what Done saves), Reset, Cancel, Done. Keyboard: Tab walks colour swatches, hex field, symbol grid (the focus ring is on the chosen symbol, else the first, as soon as it has the focus; arrows move it, Return/Space chooses, Delete clears), symbol field, Reset, Cancel, Done; Esc and Ctrl+W cancel, Return in the window applies. Several folders can be customised at once (the window starts from the first one). A folder's own colour wins over the global one; `theme` as the own colour keeps the theme's colour while a global colour is set.
- **Rendering** (`ui/Grassfield/Ui/FolderIcon.qml`, `FolderEffect.qml`, `FolderStyle.js`; separate from the icon modes of ADR-0014): a `TintedIcon` (mode unchanged) recoloured by one `MultiEffect` layer in default mode and, in an icon mode, by the icon shader itself on the artwork only (the system plate and its rim are not recoloured), with the same arithmetic (colorization 1: the luminance of the theme's folder, flap and shading, mapped onto the colour, alpha kept; tokens `folderIcon*`). No layer or effect exists for a folder without a colour (no extra cost). The colour step runs after the mode step, so Dark/Clear/Tinted still apply; in Tinted mode the folder colour wins for folders that have one, because the shader recolours the already tinted artwork (the plate and its rim keep the tint). A folder in a selected, focused row (an accent fill: Files list and column views) is drawn with `overAccent`, like every icon over an accent fill. The symbol is a `Text` over the effect inside a clipped box the size of the icon (a hostile value cannot draw outside it). Emoji are drawn opaque in their own colours (no alpha, no recolour; with an emoji font without colour glyphs the text fallback uses the shade below). A plain symbol is an engraved shade of the plate under it (macOS 26 model, `FolderStyle.glyphShade`): the plate's colour (the folder colour, or the theme's own folder colour) darkened in its hue (HSL lightness) until it reaches `folderIcon.glyphMinContrast` (3.0, gate A2 icons) plus `glyphContrastMargin` against the plate, with a 1 px light edge under it (`glyphHighlight`); a plate too dark for a darker symbol (black, very dark colours) gets a lightened shade instead. **The plate is computed from the raw icon, never grabbed from the visible one** (`FolderPlate`, `FolderStyle`; first a pass that grabbed the visible icon once per colour, size and mode, one 150 to 200 ms frame each time, so symbols popped in late and the "one frame" this spec claimed was false). A plate is a function of (icon file, size bucket, icon mode, mode tint, appearance, folder colour), and Qt's MultiEffect is arithmetic: the compiled shader's source says, on premultiplied colour c with alpha a, `c = (c - 0.5a)(1 + contrast) + 0.5a`, `c += brightness a`, `gray = dot(c, (0.299, 0.587, 0.114))`, `c = tint gray w + c (1 - w)` (w = colorization), `c = mix(gray, c, 1 + saturation)`, alpha x opacity. So the RAW icon's pixels under the symbol are read once per (icon file, size bucket 32/64/128/256: `folderIcon.plateBuckets`) as a grid of at most 12 x 12 samples (`FolderStyle.sampleBox`; a `Canvas` with `Canvas.Image`, CPU only, loads the icon by URL, draws it at the bucket size and reads back only the box under the symbol: 0 ms measured on the GUI thread, the icon's own decode is that of its provider: `image://icon` of Files is a synchronous pixmap provider, theme file URLs decode asynchronously; the read itself costs nothing on the GUI thread either way), by one `FolderIcon` at a time in the whole application (`FolderPlate.claim`), in an event-loop turn of its own and never from the visible icon or a layer. The plate of any combination is then computed from those samples (`FolderStyle.plateThrough`: the icon mode's stage (`IconModes.effect`) and then the folder colour's (`effect`) through `effectSamples`, each clamped to 8 bits like the layer, composited over the view behind a translucent Clear plate (`folderIcon.plateBackdropDark/Light`), reduced to the darkest and lightest quarter's mean, the mean hue and the luminance of the mode's own folder plate) and cached per full key (4096 entries at most), so 100 distinct folder colours, a new icon mode or a change of appearance cost 0.1 ms each and never another read. The model of the icon modes is a port of `shaders/icon.frag` (`FolderStyle.modeSamples`, `underlay`): the shader's recolouring of the artwork depends on the pixel alone (no plate or stroke analysis), so the model is its arithmetic, not an estimate. Dark darkens and slightly desaturates the folder and lifts its dark parts (the colour identity is kept), Clear makes it a flat ink whose opacity follows the folder's luminance, Tinted maps the luminance onto the two-tone ramp of the tint. The folder sits on the system plate (scaled by `iconMode.sysGlyphScale` about the centre together with the symbol) and the symbol's plate is the artwork over that system plate over the view behind it (`FolderStyle.underlay`: graphite, tinted, or the glass of Clear, light on a dark material, smoked on a light one or over the bare wallpaper, composited over the backdrop `folderIcon.plateBackdropDark/Light`); only Clear's artwork is translucent, so only there does the backdrop matter. The model is checked against the rendered pixels on a GPU scene graph (`tests/unit/tst_iconshader.qml` `test_folderModelMatchesTheShader`, run by `tests/visual/icon-a2.sh`: the Breeze folder (the WhiteSur one before 2026-10-21) and two synthetic folders, three modes, both appearances, window and wallpaper: at most 4/255 per channel; measured 1/255 at most for the WhiteSur folder and 0 for the flat ones; not re-run on the Breeze folder (test-icons is refused in the agent sandbox: NOT VERIFIED)). The folder-colour step (MultiEffect) is the arithmetic above on straight colour, exact for opaque pixels (the clamp differs from the layer's premultiplied one only where a pixel is translucent). The cache of raw reads evicts its least recently used quarter past 512 icons, so the icons on screen keep their plates. The software scene graph of the offscreen unit runner cannot draw the recolour or the shader, but the model is plain JavaScript and is tested there. Until the samples arrive (the next turns of the event loop, once per icon file) the symbol is drawn at once with the estimate of `FolderStyle.plateOf` (colour x `plateDefault` ...; calibrated on one icon theme, never used once the icon is read) and settles on the computed plate with a colour cross-fade of one motion token (`motionNormal`, at most 100 ms with Reduce Motion), no pop; an icon with no file to read keeps the estimate. An emoji is opaque and in its own colours and needs no plate.

  **One engraving rule per mode** (`FolderStyle.prefersLighter`, `glyphShade`): the shade is the plate's hue, darker or lighter than the plate until it reaches `glyphMinContrast` + `glyphContrastMargin` against the darkest plate (darker) or the lightest (lighter). Default, Dark and Clear engrave the darker shade (macOS 26: a debossed symbol; a Dark folder keeps its colour on the graphite plate); Tinted engraves the lighter shade when the mode's own folder plate (the theme's folder through the mode and the icon tint) has a relative luminance below `folderIcon.glyphLighterBelow` (0.25), darker otherwise, so the light appearance's dark tint plates take lighter symbols and the dark appearance's bright ones darker. The direction depends on the mode and its plate, never on the folder colour; a folder takes the other shade only when its plate cannot reach the contrast the preferred way (a black folder in Default, Dark, Clear and dark-appearance Tinted; the white folder in light-appearance Tinted; the accent folder in light-appearance Default, whose plate is darker than 0.115). Same colour, same mode, same appearance: same shade. Measured (nested, `tests/visual/folder-glyphs.sh` and `folder_glyph_contrast.py`, 12 folders x 4 icon modes x 2 appearances): 96/96 cells at 3:1 or more on Breeze (the base icon theme, 2026-10-21, min 3.28; the same on the former base theme) and 288/288 on the desktop and on the fallback theme (min 3.27); every symbol is drawn at the capture (the grab pass left the first captures after a change without symbol: it was still reading). Symbols per view (WhiteSur, 2026-10-20; not repeated on Breeze, only the 3:1 check was): Default and Clear in both appearances all darker except Black (and the accent folder in light-appearance Default); Tinted in light appearance all 12 lighter, in dark appearance all darker except Black; Dark lighter for 8 of 12, the pale Theme, Yellow, White and Lemon plates darker (a pale symbol on those plates would be under 3:1). Frame cost (`tests/visual/folder-glyph-perf.sh`, `qt.scenegraph.time.renderloop` per frame, nested, WhiteSur (the base theme then), 1000 folders, the first 100 with a symbol, 60 notches down and up): 1238 frames, none over 33 ms on the GUI thread or the render thread, with nothing customised, with one shared colour and with 100 distinct colours; CPU 3, 3 and 4 s (before, with the grab: 3, 3 and 5 s); the read itself, instrumented, costs 0 ms of canvas drawing and readback on the GUI thread (the icon decodes asynchronously, 11 to 45 ms in the background, once). The window's first population has frames over 33 ms in every run, nothing customised included: not attributable to folder icons.
- **Symbol rule** (`FolderStyleLogic::normalizeGlyph`, `FolderStyle.normalizeGlyph`): the first extended grapheme cluster of the trimmed text, by the whole of UAX #29 (GB3 to GB13: CR x LF, controls, Hangul L/V/T/LV/LVT, extending and spacing marks including Thai and Lao SARA AM, GB9b prepended characters, GB9c Indic conjuncts with the exact InCB=Extend class, `ExtPict Extend* ZWJ x ExtPict`, regional indicator pairs); a joiner with nothing to join is dropped; refused when over 16 UTF-16 units or when it holds a control, format (bidi marks, zero width space, ZWNJ), separator, lone surrogate or U+FFFD. Qt's own segmenter is not used (it cuts Indic conjuncts and emoji sequences differently from the standard). Both sides run one algorithm over one set of data: `scripts/dev/gen-glyph-tables.sh` reads Grapheme_Cluster_Break, Extended_Pictographic, Indic_Conjunct_Break, Emoji and the general category from the installed ICU (generation time only, no product code links ICU; ICU 78.3, Unicode 17.0 here) and writes `ui/Grassfield/Ui/GraphemeData.js` and `apps/files/src/graphemedata.inc`; `tests/shell/glyph_tables.sh` fails when they are stale and runs `scripts/dev/glyph-icu-compare.sh`, which compares `normalizeGlyph` and `isEmoji` with ICU's own grapheme segmenter on random sequences (0 differences over 3 x 100000 sequences for the C++ side and 30000 for `FolderStyle.js`); `tests/fixtures/glyph-vectors.json` (161 vectors: ZWJ sequences, flags, skin tones, keycaps, combining marks, Hangul, Indic, prepended characters, Thai and Lao AM, bidi, surrogates; the new ones answered by ICU) is read by the gtest and the QML test. Emoji or plain (`isEmoji`, both sides): the emoji selector U+FE0F, a keycap, or a character with the Emoji property (U+0080 and above: the ASCII digits, # and * have it but are text without a keycap), unless the text selector U+FE0E is present; so U+20000 (CJK) and U+1F130 (enclosed letter) are plain, a mahjong red dragon (U+1F004) is an emoji. Text-by-default emoji characters (an umbrella, a heart suit, an airplane) count as emoji without U+FE0E because this system's fonts draw them in colour (measured with Qt: the umbrella is coloured even with U+FE0E, so it stays an emoji). The heart suggestion carries U+FE0E so it stays an engraved symbol.
- **Storage** (`apps/files/src/folderstylelogic.h`, `folderstylestore.h`): the extended attribute `user.grassfield.folder` on the folder, a UTF-8 JSON object `{"v":1,"color":"#e5484d","glyph":"🎵"}`; `color` is `#rrggbb` (lower case), `accent` or `theme`, a missing `color` follows the global setting, a missing `glyph` draws nothing; unknown keys (a newer version) are kept on edit; an invalid field reads as missing; a value over 4096 bytes reads as empty and is never edited (a write is refused with a reason, a reset too: it would drop keys this version cannot read); an empty look removes the attribute. Same robustness rules as tags: only this attribute is read or written (tags and other applications' attributes are never touched); the write starts from a fresh checked read (`readAttr`) and a failed read (permission, I/O error, vanished folder, value that grows) aborts it with the system's reason; links are never followed or styled; only folders on this computer (not Trash, not remote).
- **Fallback store**: when the attribute cannot be written (a filesystem without user attributes: FAT/exFAT/NTFS, some network mounts; a read-only or immutable folder) the look is stored in the per-user file `folder-styles.json` next to `grassfield.json` (`$GRASSFIELD_CONFIG_HOME`, else `$XDG_CONFIG_HOME/grassfield`), `{"version":1,"serial":N,"folders":{"/abs/path":{"color":"#rrggbb","glyph":"x"}}}`, mode 0600, written atomically (`QSaveFile`), keyed by the cleaned absolute path (the attribute travels with the folder; the entry follows moves made in Files). The window tells the user ("Saved for your account only…"). An entry wins over the attribute (it is the user's explicit choice on this machine) and is dropped once the attribute can be written again. A store that cannot be parsed is never overwritten: writes that need it are refused with a reason, writes to the attribute still work. A reset on a folder whose attribute cannot be removed fails with the reason (the store cannot hide an attribute), but the entry saved for the account is dropped anyway and the message says so. At most 20000 entries (`kMaxFallbackEntries`): a file read with more keeps them all, a new entry is refused with a reason once full (a pruning of vanished folders starts, a later try may find room), nothing is evicted silently. Entries follow Files' renames and moves of the folder (rename, drag move, cut and paste; subfolders too), a new folder created by Files drops an old entry at its path, and entries of folders that no longer exist are pruned by a worker thread after a write (at most once a minute, or at once when a new entry finds the store full), applied at the next write: the worker resolves each entry by its canonical path, one component at a time from the root, following a symbolic link only through components on a currently mounted local disk filesystem (ext4, btrfs, xfs, f2fs, zfs, ... from `/proc/self/mountinfo`, which never touches a mount, plus `/etc/fstab`, mount points normalised so `/backup/` is `/backup`, and the `/run/media`, `/media`, `/mnt` conventions for mount points that are not mounted); every step is checked against the mount table before it is looked at, so `~/nas -> /mnt/share` (cifs) or a link that leads there through a local folder is never statted inside the share; an entry with a component on a network, FUSE or removable filesystem, under an unplugged volume or an empty fixed mount point, or whose state cannot be told is kept. Only `ENOENT`/`ENOTDIR` mean "gone" (`EACCES`, `EIO` and the rest keep the entry: a folder under a parent the user can no longer search is not pruned), an entry under a gone folder goes with it only when it is not found itself, and the worker never runs on the GUI thread. The worker owns copies of what it reads (entries, mount table) and no pointer to the store; the store's destructor cancels it, gives it 150 ms, then abandons it, so Files exits at once even when a stat is stuck in a dead hard mount (the worker ends at its next step; tests inject a fake file system and a blocking stat). Entries follow a move to the destination KIO really used: a cut-paste only for a folder the job reported as created, a move from `copyingDone` (a Rename answer in the conflict dialog gives the new name, Skip nothing). A store whose JSON would exceed 4 MiB (the reader refuses a bigger file as broken; long paths reach it before 20000 entries) is refused on write with a reason. Moves done outside Files, and undo of a Files move, are only caught by that pruning (the look is lost, never wrongly inherited by a different folder except until the next write). Error strings of the store go through `QCoreApplication::translate` (French catalog).
- **Change detection**: the model reads a folder's look once per row, lazily (only rows the views ask for; one `lgetxattr` plus a hash lookup), and drops it when KIO reports the folder changed, after a reload, or when Files writes it (`folderStylesChanged`). KIO does not report an extended attribute change, so the model also watches the shown local folder (`QFileSystemWatcher`: inotify delivers `IN_ATTRIB` of the entries to a watch on the folder; verified by the gtest `AWatchOnTheFolderSeesAnotherToolSettingTheAttributeOfAnEntry`): 200 ms after the last event of a burst, and at the latest 500 ms after its first one (`FolderStyleLogic::debounceDelay`: a change every 50 ms in the folder does not postpone it for ever), the rows whose look was read are read again (one `lgetxattr` each) and only the changed ones are announced, so a look set by `setfattr` shows in an open window without Ctrl+R (`tests/visual/folder-colours-live.sh`). Cost: none while nothing changes in the folder. `FilesApp` watches the store file (QFileSystemWatcher on its directory) and re-reads when its stamp changes (`allFolderStylesChanged`). `serial` moves on every successful write (attribute or store), so one file is the change signal for other processes. The desktop (`shell/desktop/DesktopFiles.qml`) reads its folders' attributes with one `getfattr -h -d -e hex` process per listing change (absent `getfattr`: global colour only) and watches the store file (`FileView`), re-reading when it changes; precedence entry > attribute, same as Files. An attribute written by another tool without touching the store shows on the desktop at its next listing change.
- **Interop**: KDE stores a folder's icon in `.directory` (`Icon=folder-red`, an icon *name*, a file inside the folder); GNOME stores `metadata::custom-icon` in gvfs's metadata database. Grassfield reads and writes neither: `.directory` would cost an extra file open per folder shown, and a theme icon name (Breeze has `folder-<colour>` icons) cannot express a free colour, a symbol or the accent. Folders customised by Grassfield show their colour only in Grassfield (the attribute is ignored by Dolphin/Nautilus).
- **Measurements** (gtest `FolderStyleStore.ThousandFoldersCostLittleWithoutCustomisation`, 1000 folders created under `.dev`, this machine): reading the look of all 1000 takes 26.6 ms cold (one `lgetxattr` each, nothing customised) and 16.6 ms with 100 customised; the model only does this for the rows its delegates ask for, not for the whole folder.
- Tests: `tests/unit/files/tst_folderprune.cpp` (pruning against a fake file system and mount table: a link into a share or through a local folder to one is never statted inside it, link chains and loops, only ENOENT/ENOTDIR is gone, mount points with a trailing slash, exit while a stat is blocked, the debounce max wait), `tests/unit/files/tst_folderstyle.cpp` (format, shared symbol vectors, mount table, pruning off the GUI thread and only of local entries, cap and byte limit, paste re-key, watch premise, grapheme handling, round trip, unknown keys kept, other attributes untouched, failed read aborts the write, read-only folder uses the fallback, entry yields to the attribute, corrupt store never overwritten, links/files/missing refused, reload sees another process, performance), `tests/unit/tst_foldercolors.qml` (the plate arithmetic against the measured plates, A2 and one engraving direction per mode and appearance, one read per icon file whatever the colours, setting and per-folder precedence, stored value, getfattr and store parsers, settings key, live switch of `FolderIcon`: no layer for the theme colour), `tests/unit/tst_settingsstore.qml` parity and `tests/shell/settings_roundtrip` for `icons.folderColor`. Captures: `tests/visual/folder-colours*.sh` (not regression scenarios).
- Limits: the symbol picker is a fixed set plus a text field (no emoji panel); symbols are not translated or described beyond their own glyph for screen readers; the desktop does not show a folder's look when the path contains characters `getfattr` escapes; Search and Dock stacks are not applicable yet.

## Default file manager (owner request 2026-10-20; macOS model)

macOS: the Finder is the first Dock tile, cannot be removed, and opens every folder the system opens. Grassfield Files is the same.

- **Dock:** a fixed first "Files" tile before the Apps tile (docs/specs/dock.md item 20); own icon `org.grassfield.Files` (an original green folder, `branding/icons/apps/`, installed in hicolor; Settings and Preview have `org.grassfield.Settings` / `org.grassfield.Preview`). The generic `system-file-manager` is never used as the Files icon: the theme that was the base until 2026-10-21 (WhiteSur) drew it as a Finder-like face, which is Apple trade dress; Breeze draws a filing cabinet.
- **Folders opened by the shell** (desktop double-click, Dock Trash, Search "Show in folder", Apps `revealExecutable`, any `gio open` / `xdg-open` of a folder) open in Grassfield Files in a REAL session (`GRASSFIELD_SESSION=1`, not dev), whatever the user's default handler is. `Apps.folderAware` / `AppLaunch.folderAwareArgv` rewrite `gio open T...` and `xdg-open T` into `bash shell/services/open-real.sh <opener> T...`, started through the app-scope launch path (`Apps.scoped`, uwsm-app): every folder target (a directory, a `file:` URL of one, `trash:///`) goes to one `grassfield-files` process, every other target to the opener the shell asked for (files keep the user's default handler). Without `grassfield-files` on PATH everything goes to the opener. `gtk-launch`, `gio trash` and the like are unchanged. A dev session keeps the dev open policy (ADR-0011, `scripts/dev/open-policy.sh`).
- Tests: `tests/shell/open_real.sh` (the script with fake Files, gio and xdg-open), `tests/unit/tst_applaunch.qml` (`folderAwareArgv`), `tests/unit/tst_dockmodel.qml`.

## Share menu (ADR-0045 OC-13, LocalSend)

macOS: the toolbar's Share button and the item menu's Share open the sharing services, nearby-device sharing first. Here the
one service is LocalSend, which Omarchy installs (`install/omarchy-base.packages`) and offers in its own Share menu.

- **Where:** a Share button, a bare glyph (`ViewGlyph` "share": a tray open at the top and a rising arrow) before Tags in the
  toolbar, and Share… « Partager… » after Copy / Copy as Pathname in the item menu (and the Action menu), which opens the
  same menu (`BrowserTab.shareMenu`) where the item menu was (macOS 13 and later; `openShareMenu`, at the menu layer's
  anchor, a row selected when the item menu came from the keyboard). Its first item is "Send with LocalSend…" « Envoyer avec LocalSend… ». Both exist only while `localsend` and `systemd-run` are on
  PATH (`FilesApp.localSendAvailable`, `QStandardPaths::findExecutable`, looked up when a window opens or becomes active and
  each time a menu is built). The button is dimmed without a selection, in the Trash and in Applications; the item is
  dimmed unless every selected item is a local file or folder (`ShareLogic.canSend`: `file:///` URLs only, so no `trash:/`,
  `grassfield-apps:/`, network or search location). The Open and Save panels have no Share.
- **Send:** `ShareLogic.sendArgv` builds Omarchy's own invocation (`bin/omarchy-menu-share`): `systemd-run --user --quiet
  --collect localsend --headless send <path> ...`, one argument per item (each once, in the selection's order), never through
  a shell. No `--` (LocalSend's command line has none, Omarchy passes the paths directly): every path is absolute, so none can
  read as an option. `FilesApp::sendWithLocalSend` checks the vector again (exactly that program and options, then paths that
  start with "/", hold no NUL and exist) and starts it detached; `GRASSFIELD_FILES_NO_LAUNCH=1` blocks it like any launch. A
  development session (`GRASSFIELD_DEV=1`) sends nothing (security review of OC-13, LOW 2): `systemd-run --user` starts
  LocalSend in the user's service manager with its environment, so it would open on the owner's real desktop with the
  files. There the item stays in the Share menu, dimmed (`ShareLogic.menuItems`, so the nested session still shows the menu
  as it is), the tab refuses with "Not sent: a development session doesn't start LocalSend (it would open on the real
  desktop)." in the banner, and `FilesApp::sendWithLocalSend` refuses the same way (`runmode::dev()`, as Preview's
  `openLink`). A refusal or a start failure shows in the window's banner. LocalSend then shows its own window: Omarchy floats and sizes it
  (`default/hypr/apps/localsend.lua`), a rule the Grassfield session loads only once the per-application rules of ADR-0045
  OC-12 port it; until then it opens where Grassfield's placement puts a new window.
- Tests: `tests/unit/tst_filesshare.qml` (URL to path, local-only selections, the vector, dimmed and never sent in a
  development session), `tests/unit/tst_filesbrowser.qml` `test_shareSendsWithLocalSend` (Share… after Copy, the Share menu
  it opens at the item menu's point, the send through the stand-in FilesApp, nothing from Applications, a development
  session's refusal in the banner, no Share without LocalSend), `tests/unit/tst_filesfinish.qml` (Share, Tags and Action in a
  row), `tests/unit/files/tst_fileops.cpp` `SendWithLocalSendRefusesOtherVectorsAndADevSession` (C++, not compiled in the
  cloud session).
  Not verified: the C++ (not compiled in the cloud session), the glyph and the menus on screen (visual NOT verified), a real
  send to a device.

## Toolbar capsules (visual audit 2026-10-25, priority 11)
macOS model, measured: back/forward are one 72 x 36 capsule (`toolbar.groupButton` 34 each), the view switcher a 36-pt capsule whose selected view is a lighter pill, the search a 36-pt circle that expands to `files.searchWidth` 200 while it has the focus or text. Settings has the same back/forward capsule over its detail pane (history of the panes, `apps/settings/qml/NavHistory.js`, `tst_navhistory.qml`). Fills are `Appearance.buttonFill` (6 % grey in light), the pill `Appearance.chipFill`; contrast in `WindowSurfacePairs`.

Design polish step 23 (ADR-0039): every toolbar capsule is the shared `RimmedCapsule` (`toolbar.*`: a white fill lifted by a soft shadow, no outline; ADR-0024 amendment 2026-11-03), Tags and Action are two bare glyphs with no capsule (as Finder draws Share, Tags and Action on a white window), and the search circle is a lifted capsule that stays one once open, with the shared focus ring outside it and a clear button. A folder that has listed nothing after `files.loadingDelay` shows the shared `Spinner` and "Loading…" in its view. Files reads Increase Contrast and Text size; the path bar's segments and the preview pane's actions take the keyboard.
