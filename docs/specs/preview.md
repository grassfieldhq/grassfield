# Preview + Glance spec · apps-engineer · M4

## macOS reference behavior (described in words)
- Preview is one window with a toolbar (sidebar toggle, zoom out/in, fit, rotate, page navigation, search), a
  sidebar (page thumbnails of a document, the list of files when several were opened) and the document. The title is
  the file name. Zoom, rotation and page are properties of the view only.
- Quick Look is a small floating panel that shows the selected file at once: Space opens it, Space or Esc closes it,
  the arrow keys move between the selected files, a button hands the file to the full viewer.

- Live Text (Settings > General > Language & Region): over the text of a picture the pointer is an I-beam; a drag selects
  words in reading order across lines, a double click selects a word, a click clears the selection; Command-C and the
  context menu's "Copy Text" copy it, "Select All Text" selects all of it; the selection is drawn in the text highlight
  colour. A QR code gives a data detector button at the bottom right of the picture (a link opens in the browser).
- A file manager window (Finder) shows the opened image at once, and the arrow keys then walk the other files of its
  folder in the order of the Finder window. The opened file is always part of that walk at its sorted position, even
  when it is hidden; unreadable neighbours are skipped; an unreadable opened file shows an error in its place.

## Purpose and non-goals
View files without editing them. The viewer is "Preview" (code `grassfield-preview`, app id
`org.grassfield.Preview`); the quick look is called "Glance" (app id `org.grassfield.Preview.Glance`; never the Apple
name). Non-goals for v1 (Known limitations): Export, annotations, markup, forms, editing, printing, encrypted PDF,
network streams, image adjustments, HEIC unless a Qt plugin is installed, syntax highlighting, Glance as a persistent
single instance.

## Behavior
1. P1 Command line: `grassfield-preview [--glance] [--] <path-or-file-url>…`. Arguments are validated in
   `src/previewlogic.cpp`: a path (relative ones against the current directory) or a `file:` URL (empty host or
   `localhost`, no query or fragment). Any other scheme (`http`, `ftp`, `smb`, `data`…), a remote file host, a
   directory, a device, a FIFO or a missing file is refused with one message on stderr and in the window. At most 200
   files, duplicates removed.
2. P2 Window (`qml/Viewer.qml`): toolbar with Sidebar, zoom out, zoom label, zoom in, Fit, Rotate, previous/next page
   and a search field (PDF); title = file name; opaque; light/dark, Reduce Motion, Increase Contrast and Text size follow
   `grassfield.json` (read only, watched), as in every app. The window and the Glance draw the window neutrals of
   ADR-0024 (`Appearance.windowSurface`: #FFFFFF / #292929, secondary text `Appearance.windowSecondary`), not the shell's
   material tint; text on a floating glass capsule (search, Info) keeps the glass grey. Selected text is drawn in the
   text highlight colour (`Appearance.highlight`, Settings > Appearance), as in Settings and Files. The title, the search
   field and the PDF's file names use the body size, which follows Text size; the document's own text is content and
   keeps its reading size (ADR-0039 step 3). The sidebar lists the files when more than one was given and the page
   thumbnails of a PDF. The window's structure is every app's (ADR-0039 step 16): the sidebar a floating panel (ADR-0024 amendment 2026-11-03: inset 8, radius 18) in the sidebar
   fill with the content beside it; the toolbar's groups and search circle
   on the toolbar's rimmed capsules (`toolbar.capsule` 36) with 34-pt buttons (`toolbar.groupButton`); overlay scroll bars
   on the image, the text and the sidebar's lists; a 1-px rule under the toolbar once the view's content has scrolled
   under it (D3; a PDF past its first page).
3. P3 Images (`ImageView.qml`): any format Qt can decode (`qt6-imageformats`, SVG through `qt6-svg`); fit (shrinks
   only) or zoom (0.05 to 16, Ctrl+wheel, pinch, + / - / 0 for 100 %, Ctrl+9 for Fit); rotation by quarter turns
   (Ctrl+R / Ctrl+L, view only); EXIF orientation applied; multi-page TIFF steps through pages (PgUp/PgDn, toolbar);
   animated GIF and WebP play through `AnimatedImage`; under Reduce Motion they wait on their first frame with a play
   control (a glass capsule at the bottom, Play / Pause), as macOS with "Auto-play animated images" off: Reduce Motion is
   for the chrome, the content is the viewer's to play; the play ends with the setting's change or another file (ADR-0039
   step 6). Decoding goes through `image://preview/<frame>/<file token>` (the sidebar's `image://preview/thumb/<file token>`):
   the token stands for the file's path for the app's life (`PreviewApp::tokenFor`), so the folder listing, which moves the
   opened file to another index, never decodes it twice nor shows a cached picture under another file's name. A vector
   picture (`.svg`, `.svgz`) over 8 MiB is refused from its size ("This file is too large to preview."), never parsed.
   Every file shown is inspected (type sniffing, size, frames, text) on a worker thread (`PreviewApp.requestInspect`,
   `inspected`; the newest request counts): the window shows the file's name meanwhile, no message and no viewer, and a
   sidebar text plate's first lines are read on a worker too (`snippetFor`).
4. P4 PDF (`PdfView.qml`): QtPdf (`PdfMultiPageView`, pdfium, no JavaScript): continuous pages, zoom, fit to width,
   rotation, page navigation (PgUp/PgDn, Home/End, arrows turn pages, toolbar), thumbnails, text search (Ctrl+F,
   Enter next, Shift+Enter previous, Esc closes). Encrypted documents show a notice ("not supported yet").
5. P5 Text and code (`TextView.qml`): read only, monospace, always `PlainText` (never markup), selectable; zoom
   scales the font. A text over 64 K characters comes in pieces of whole lines (`inspect` `chunks`) laid out by a list,
   only the pieces on screen (a zoom step or a window width re-lays out a screenful, not 2 MiB; the width follows a live
   resize once it settles); Select All and Copy take the whole text, a drag selects within one piece. Files over 2 MiB show "This file is too large to preview"; files with NUL bytes in the first 8 KB
   show "This file is not text". Decoded as UTF-8. Playlists (M3U, PLS, XSPF, WPL, every ASX suffix: asx, wax, wvx,
   wmx) are text, never handed to the player and never followed or fetched: decided by the canonical MIME type,
   its aliases and ancestors, the suffix, and the first 512 bytes (extensionless files).
   Markdown (owner report on 1.0.0-rc9, "Preview does not preview .md files": they showed their source; macOS Quick Look
   and Preview show a Markdown file formatted). A file of type `text/markdown` (or a type inheriting it: the `.md`,
   `.markdown`, `.mkd` suffixes of shared-mime-info) shows rendered in the viewer and the Glance: headings, emphasis,
   lists and task lists, block quotes, code (monospace, on `Appearance.chipFill`), links (accent colour), tables, rules
   and pictures. The backend reads it with Qt's own Markdown reader (`QTextDocument::setMarkdown`, GitHub dialect, raw
   HTML off: the document's own tags stay text) on the inspection worker and hands the view rich text
   (`inspect` `markdown`, `html`; `previewlogic` `markdownHtml`), shown by a read-only, selectable `TextEdit` in
   `RichText` (body `preview.markdownFontSize` 14 in the system font, margin `preview.markdownPadding` 24; zoom scales
   it; Copy gives the text). A picture is shown only when it is a local readable regular file that Preview shows as an
   image (a path relative to the document, an absolute path or a `file:` URL; not under /proc, /sys, /dev; within the P9
   caps), served by the image provider under its token (never by path, never fetched: an `http`, `data:` or missing
   picture shows its alternative text), at most 64 per document, shrunk to the column (`Markdown.js`). A click on an
   http(s) link opens it in the browser through `PreviewApp.openLink` (refused in a dev session, ADR-0019); other targets
   (another file, an anchor) do nothing. View > Show Markdown Source and the toolbar's source button (`icons/source.svg`)
   show the plain text instead (monospace, `PlainText`), View > Show Formatted Text goes back; the choice is the view's,
   per file. A Markdown file over 512 K characters (`kMaxMarkdownChars`) shows its source only. Other text kinds (plain
   text, logs, source code, JSON, YAML, TOML, XML, HTML, CSV, shell scripts, subtitles, diffs) show their plain text.
6. P6 Audio and video (`MediaView.qml`): QtMultimedia `MediaPlayer`, only the local `file:` URL of a validated file;
   play/pause (button, Space in the viewer), a position slider, elapsed and total time. Glance and the Preview window start playing at
   once (Quick Look; the sound goes to the default output, so the system mute applies). A decode failure shows the player's message.
7. P7 Glance (`qml/Glance.qml`): same binary with `--glance`. A normal toplevel with app id
   `org.grassfield.Preview.Glance`, sized for the content of the first file on the screen it is shown on (image:
   native size scaled down to fit `preview.glanceScreenFraction` of the screen for the content area; PDF, text, video
   and audio their token sizes, capped the same way; the header comes on top), header with the file name, "n of N" and
   "Open with Preview". Qt only learns the output after mapping: the window is sized for Qt's first screen, then once
   for the screen it entered, requested as a fixed size (minimum = maximum, which Hyprland applies to floating windows,
   centred) and released after `motion.normal` (1200x800 PNG on 1920x1080: 1134x796).
   Space, Esc and Ctrl+W close it; Left/Right move through the files (wrapping, fitted into the same window);
   + / - / 0 zoom; Ctrl+O or the button opens the full viewer (`grassfield-preview -- <files>`, detached) and quits.
   The Hyprland rule `gf-glance` (`config/hypr/grassfield/windows.lua`) floats and centers it and sets
   `decorate = false` so the compositor plugin draws no titlebar. The header is therefore the panel's title bar (owner
   report on 1.0.0-rc9, "the Preview window cannot be moved": it started no move): it is the apps' `UnifiedToolbar`
   (no lights, no title of its own), so a drag on its empty space moves the window (the compositor's interactive move),
   as a Quick Look panel moves by its title bar; a drag from its controls does not; a double-click does nothing (a panel:
   no zoom, no minimize).
8. P8 Triggers: Files (Space, item menu "Glance at …", `docs/specs/files.md` F12) and desktop icons (Space toggles
   it, `docs/specs/desktop.md`; OFF in desktop keyboard safe mode, back with the macOS-model redesign). There is no single-instance logic in the app: a second launch is a second window.
   (Off in safe mode.) The desktop toggles through `shell/services/GlanceApp.qml`, which owns the process and closes it when Space is
   pressed again (a layer surface keeps the keyboard focus when a window maps, so the Glance cannot always close
   itself there: click it to use the arrow keys).
9. P9 Untrusted input: only local regular files; `QImageReader::setAllocationLimit(256)` for every decoder (also QML
   `Image`/`AnimatedImage`); images over 16384 px per side or 256 MiB at 4 bytes per pixel are refused before decoding
   with a notice; PNG headers are sniffed so that a huge image gets the right message; the file is never opened for
   writing and never executed; no network access; text is `PlainText`, except a Markdown document's rendered view (P5:
   Qt's reader with raw HTML off, pictures only from the image provider).
10. P10 Global menu (T1, master-prompt 5.7, ADR-0008): the viewer (not a Glance) exports File (Close Window), Edit
    (Copy and Select All of a text file or of the text of an image (P13), Find…, Find Next Ctrl+G, Find Previous Ctrl+Shift+G), View (Show/Hide
    Sidebar, Actual Size, Zoom to Fit, Zoom In, Zoom Out), Go (pages, previous/next file) and Tools (Rotate Left/Right)
    through DBusMenu (`qml/GlobalMenu.qml`) when `com.canonical.AppMenu.Registrar` is on the session bus at start
    (`apps/globalmenu.h`); otherwise nothing is created and the bar keeps T0. The toolbar stays. The file view is
    clipped (PDF pages never draw over the toolbar).

11. P11 Browsing the folder (Track B2): when one image is opened (a Glance: one file of any kind Preview can show), the
    other files of its folder can be browsed. The list follows the Grassfield Files order (same comparison: numeric,
    case-insensitive names; key, direction from `QSettings Grassfield/Files`, read only). Only regular readable
    visible files of a wanted kind by file name (images for the viewer; every previewable kind for a Glance; symlinks to
    files followed, broken ones skipped); the opened file is always in the list at its sorted position, hidden or
    unreadable or not. At most 200 entries (a window around the opened file), at most 20000 directory entries scanned.
    Left/Right (and Page Up/Page Down on images, the toolbar arrows) move without wrapping; the subtitle shows
    "n of N"; the sidebar lists the files as thumbnails (decoded at their size by `image://preview/thumb/<index>`), Selection is a ring in the accent colour around the thumbnail (macOS Preview), never a solid plate over it; a text file shows its first lines (`PreviewApp.textSnippet`, 12 lines of 40 characters) on white paper (GF-101).
    starts closed for a folder and open for several named files; Info (Ctrl+I) shows kind, size, dimensions, date and
    folder; a slideshow (full screen, `preview.slideshowInterval`) steps through the images and stops after the last;
    zoom and rotation are view-only. Everything is read only: nothing is ever written.
12. P12 Asynchronous listing: the opened file is shown immediately. The folder is listed in a worker thread
    (`PreviewApp::startBrowse`, started after the window's first frame so that it never competes with the first
    render); the GUI thread never blocks. The arrows and "n of N" appear when the list arrives (`files`, `startIndex`,
    `listing` change notifications); the viewer stays on the opened file (same file, same viewer, no flash). The
    listing is cancelled (a flag checked per directory entry, then the thread is joined) when the application quits or
    the backend is destroyed. `GRASSFIELD_PREVIEW_TIMING=1` prints `TIMING first-frame` and `TIMING list-ready` on
    stderr. Measured offscreen (software renderer, machine at load 10 of 8 cores), time to the first frame: 1,000
    images 404-648 ms, 5,000 images 513-708 ms, 20,000 images 313-645 ms (no dependence on the folder size); the list
    is ready after about 0.6-1.0 s, 1.1-1.7 s and 2.8-4.3 s.
13. P13 Select Text in Images (ADR-0045 OC-2; macOS: Live Text; setting `preview.textInImages`, default on, Settings >
    General > Language & Region "Select Text in Images"). The viewer and the Glance (one image view, `ImageView.qml`) read
    the text and the QR codes of a still image (one frame, not animated) when the setting is on:
    - Reading (`ImageText.qml`, one per window, held by `Content.qml`): once the view has rested on an image for 300 ms
      (1.5 s while the computer runs on its battery, `PreviewApp.onBattery`; the arrow keys held through a folder start
      nothing), `PreviewApp.recognize` runs zbarimg and tesseract in the
      background; a new image or the setting going off cancels what still runs (`cancelRecognition`); a run per image
      shown, nothing stored. The languages are asked once per window (`tesseract --list-langs`): the traineddata of the
      session's language (`Qt.locale().name`, "fr_FR" → `fra`, Chinese by script) then English, among the installed
      ones ("fra+eng"); none of them installed: no text (one journal line).
    - The backend (`src/previewapp.cpp`, `src/previewlogic.cpp` `recognitionCommand`): three allowlisted commands, each
      program looked up on the PATH at use time, an argument vector (never a shell): `tesseract --list-langs`;
      `tesseract stdin stdout --oem 1 --psm 3 --dpi 300 -l <langs> tsv` (Omarchy's `omarchy-capture-text` options, a whole
      page's segmentation instead of its one block); `zbarimg -q -Sdisable -Sqrcode.enable -` (Omarchy's
      `omarchy-capture-qr`: QR codes only, the other symbologies false-positive on screen content). `<langs>` is one to
      four `[A-Za-z0-9_]` names joined by `+`. The image is the file of the list (an absolute path to a regular file,
      not under /proc, /sys or /dev, an image by type), decoded by Qt in a worker thread with the viewer's caps, EXIF
      orientation applied, decoded at 4096 px per side where the format scales while decoding (JPEG) and scaled down to it
      otherwise, flattened on white and handed to the tool on its standard input as a grey PGM, decoded once for both
      tools of an image (a request that comes while the decode runs waits for the same one; the last picture is kept for
      the image shown); the tools run at nice 19 with `OMP_THREAD_LIMIT=1`: the tools never parse the file (zbarimg's ImageMagick coders, tesseract's "list of images"
      reading of a text file), and the boxes are in the pixels Preview shows. Each run is killed after 60 s or 4 MiB of
      output; the answer is `recognized(request, tool, exitCode, output)` (-1: not started, killed, crashed, not decoded).
      A missing tool: `recognize` returns 0, no overlay, no chip, no message on screen, one journal line per tool
      ("grassfield-preview: tesseract is not installed: no text selection in images").
    - Text (`TextInImages.js`, `TextLayer.qml`): tesseract's TSV words (level 5) grouped into lines in its reading order
      (block, paragraph, line); a word below confidence 30 and a line averaging below 50 are dropped (the grain of a
      photograph). The layer lies on the picture with its size, centre and quarter turns, so the zoom and the rotation
      need no mapping. Over a line (its box, 20 % of its height above and below) the pointer is an I-beam; a press on a
      word and a drag select whole words from the anchor to the word nearest the pointer (the nearest line by distance,
      then its nearest word), across lines in reading order; a double click selects the word; a click clears the
      selection; a press elsewhere clears it and pans as before (the double click of Zoom to Fit stays off the text). The
      highlight is one box per line from its first to its last selected word, the text highlight colour
      (`Appearance.highlight`, Settings > Appearance) at `preview.textSelectionOpacity`, radius
      `preview.textSelectionRadius`, `preview.textSelectionOutset` past the ink boxes. Copy (Ctrl+C, Super+C as
      forwarded, Edit > Copy, the context menu's "Copy Text") puts the words on the clipboard, a space within a line and a
      line break between lines and paragraphs; Ctrl+A, Edit > Select All and "Select All Text" select every word. The
      context menu (right button over a picture that has text) is the app windows' `MenuPopup`.
    - QR codes (`CodeChip.qml`): each code (at most 4, duplicates dropped; a code's own line breaks kept) gives a glass
      capsule (`toolbar.capsule` tall, the play control's material) at the bottom right of the view, a glyph, a label and
      a 24-pt push button concentric with it. An http(s) link without user information, space, control or format
      character (at most 2048 characters) names its host and "Open Link" hands it to `xdg-open` through
      `PreviewApp.openLink`, which checks it again (`isOpenableLink`, strict URL) and refuses in a dev session (ADR-0019);
      any other code is labelled "QR Code" (numbered when there are several) and never shown, since it may be a Wi-Fi
      password or a one-time-password secret: "Copy" puts it on the clipboard with the password-manager hint
      (`x-kde-passwordManagerHint`, as Omarchy's `wl-copy --sensitive`), so the clipboard history (ADR-0034) skips it.

## Acceptance criteria
| ID | Test | Level |
|---|---|---|
| P1 URL validation, P9 size caps, P5 caps, routing by type, P11 browse list (hidden/unreadable opened file, unreadable siblings, symlinks, a file that disappears, cancel), P13 commands and links | `tests/unit/preview/tst_previewlogic.cpp` (gtest, 24 tests, run by `scripts/dev/test.sh`) | L0 |
| P13 languages, TSV, hit testing, selection and copied text, links, QR codes; one reading per image, cancel, missing tools; the layer on the picture, drag, I-beam, context menu, chips | `tests/unit/tst_previewtextinimages.qml` | L0 |
| P13 the Settings row | `tests/unit/tst_settingslanguage.qml` | L0 |
| P11-P12 viewer state, list arriving after the opened file | `tests/unit/tst_previewviewer.qml`, `tests/unit/tst_previewlisting.qml` | L0 |
| Off the window's thread: inspection on a worker (newest answer kept), the SVG bound, the text pieces, sidebar snippets on a worker, one decode for both recognitions at nice 19 with one OpenMP thread, the battery rule | `tests/unit/preview/tst_previewapp.cpp`, `tst_previewlogic.cpp` (gtest), `tests/unit/tst_previewasync.qml` | L0 |
| P11 browsing with the arrows, rotate/zoom, sidebar, info, Glance arrows | `tests/visual/preview-browse.sh` (nested, standalone) | L1 |
| P5 Markdown: type, pictures (local images only, never fetched, never a device or FIFO, bounded), raw HTML as text, rendered HTML from the backend, long documents as source | `tests/unit/preview/tst_previewlogic.cpp` (Markdown.*), `tst_previewapp.cpp` (MarkdownIsRendered...) (gtest) | L0 |
| P5 Markdown view: rendered then source, selection and copy of the text, pictures fitted, theme colours, web links only | `tests/unit/tst_previewmarkdown.qml` | L0 |
| P7 the Glance header moves the window, not from a control, no double-click action; a drag from any app toolbar control never moves its window | `tests/unit/tst_previewglance.qml`, `tests/unit/tst_windowcontrols.qml` | L0 |
| Moving the viewer (image, Markdown) by its toolbar and the Glance (Markdown, image) by its header; Markdown rendered, light and dark | `tests/visual/preview-move.sh` (nested at 1.25, standalone) | L1 |
| lint | `scripts/dev/qmllint.sh` (covers `apps/**`) and `check-textformat.py` | L0 |
| config | `Hyprland --verify-config` for `dev.lua` and `session.lua` with `GRASSFIELD_CONFIG_DIR` | L0 |
| P2-P7 | nested screenshots: image + zoom, multi-page TIFF, GIF, PDF with thumbnails, text, binary and 3 MB text notices, video, audio, Glance from Files and from a desktop icon, multi-file Glance, light and dark | L1 |
| P9 | nested: 50000 x 50000 PNG header shows the "too large" notice (RSS stays near 160 MB), `http://` and `file://host/` arguments refused | L1 |
| P7 sizing | nested GF-REF 1920x1080 (`scripts/nestctl clients`): 1200x800 PNG 1134x796, PDF 620x796, text 720x560, video 800x520 | L1 |
| P10 | `tests/integration/global_menus.sh` T1c: menus in the bar, Go > Next File and File > Close Window clicked with the pointer; phase B (no registrar): T0, clean log | L1 |
| Encrypted PDF, HEIC, real audio output, compositor titlebar skip (`decorate = false`) | not testable here (no encrypted sample, no HEIC plugin, plugin not loaded in nested) | L2 (owner) |
| P13 with the real tools: a screenshot and a photo (EXIF-rotated) with text, French and English traineddata, a QR link and a QR Wi-Fi code, Ctrl+C and Super+C pasted elsewhere, the clipboard history skipping the QR copy, Glance, tesseract or zbar removed | nested screenshots on the owner's machine (not run yet) | L1 |

## Interfaces / contracts
- Desktop entry `org.grassfield.Preview.desktop`: `Exec=grassfield-preview %U`, MIME types of the common image, PDF,
  text, video and audio formats. Glance has no desktop entry.
- Settings: `preview.textInImages` (boolean, default true; read with the appearance from `grassfield.json`, watched).
- Commands (P13, looked up at use time, optional): `tesseract` with its traineddata (`tesseract-data-eng`, and the
  session language's), `zbarimg` (`zbar`); `xdg-open` for a QR code's link.
- Environment: `GRASSFIELD_PREVIEW_QML` (dev QML dir), `GRASSFIELD_PREVIEW_CMD` (callers: program and arguments of
  the dev build; `--glance` in it is ignored), `GRASSFIELD_CONFIG_HOME` (appearance file), `QT_QUICK_CONTROLS_STYLE`
  (default Basic, for QtPdf's views).
- Tokens: `preview.*` group of `ui/tokens/tokens.json`, plus `typography.monoFamily`.

## Dependencies (verified 2026-10-17)
Qt 6.11.2 (Core, Gui, Qml, Quick; runtime QML modules QtQuick.Pdf from `qt6-webengine`, QtMultimedia from
`qt6-multimedia`, image plugins from `qt6-imageformats`/`qt6-svg`), gtest (tests only). No new package in the repo
environment. P13 uses `tesseract`, `tesseract-data-eng` and `zbar`, Omarchy base packages (`install/omarchy-base.packages`
of v4.0.6), at run time only and only when installed (no package dependency of Grassfield). Build: `apps/preview/build-direct.sh` (g++), `CMakeLists.txt` for the package (not built here, cmake
is not installed).

## Known limitations
- Markdown: Qt's reader (CommonMark with GitHub tables, task lists, strikethrough and autolinks), not every extension
  (no footnotes, math, diagrams, emoji shortcodes, heading anchors); raw HTML in a document shows as text; a remote
  picture shows its alternative text (never fetched); a link to another file or an anchor does nothing; no syntax
  highlighting in code blocks; the source view's choice is not remembered between files.
- Read only: no Export, annotations, page editing or printing.
- Toolbar buttons are text (no zoom/rotate icons in the design system yet).
- The PDF page view does not scroll by arrow keys (it is a TableView): arrows turn pages, wheel scrolls.
- A Glance is sized for its first file; later files of a multi-file Glance are fitted into that window. Moving it
  to another output keeps its size.
- Glance opened from the desktop (OFF in desktop keyboard safe mode, back with the macOS-model redesign) does not
  take the keyboard focus (layer-shell on-demand focus): Space on the desktop closes it; click it before using
  the arrow keys.
- libtiff prints "foo: Not a TIFF or MDI file" to stderr while Qt probes multi-page TIFF; harmless.
- Select Text in Images (P13) reads still images only: not a page of a multi-page TIFF, not an animated GIF or WebP, not
  a PDF (a PDF's own text is selectable through QtPdf; a scanned PDF has none), not a video frame.
- Its accuracy is tesseract's: screenshots of plain UI text read well, photographs, handwriting, stylised or very small
  text and text at an angle less so (the boxes are axis-aligned, a word at an angle gets a box around it); words below
  the confidence floor are left out, so a part of a line can be missing. Only the installed traineddata are used: the
  session's language and English (Omarchy installs `tesseract-data-eng` only; French needs `tesseract-data-fra`), no
  automatic detection of other languages or scripts. Images larger than 8192 px per side are read scaled down.
- Not built from macOS Live Text: the Live Text button that highlights every text of the picture, data detectors in the
  text (dates, addresses, phone numbers), Look Up, Translate and Share in the context menu, triple click (line), the
  selection scrolling the view when a drag reaches its edge, and Live Text in video and in Quick Look's other kinds. A
  QR code's chip has no target-app icon (the browser's), and its glass is the window's opaque material (the play
  control's): the blur of the picture behind it waits for ADR-0024 phase 3.
- A QR code's link does not open from a dev session (ADR-0019 guard), and only http and https links open; any other code
  is copied, never shown.
