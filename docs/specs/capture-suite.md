# Capture suite spec (plan) · shell-engineer, platform-engineer, apps · ADR-0066 (Proposed)

Status: design and plan only. Nothing here is built. Owner request of 2026-11-22: « Pour la capture d'écran je la veux
riche comme CleanShot sur macOS, avec toutes ses fonctionnalités. » Base: main e4f6dc49 (1.0.0-rc9). Architecture:
docs/decisions/ADR-0066-capture-suite.md. The shipped capture is specified in docs/specs/system-dialogs.md §10, and this file
does not change it. It adds the next layers on top.

Naming (CLAUDE.md, master-prompt §5.5):
- The UI never shows "CleanShot", "Quick Access Overlay", "Markup", "Live Text" or any Apple name.
- UI names are generic and follow macOS 27 wording where that wording is a plain word:
  - the floating thumbnail is "thumbnail" (Options: "Show Floating Thumbnail"),
  - the editor is the **Screenshot** app ("Annotate" as an action),
  - "Pin to Screen", "Capture Text", "Capture Scrolling Area", "Recent Captures", "Redact", "Pixelate".
- Code names: `CaptureThumbnails` (shell), `grassfield-screenshot` (app, `org.grassfield.Screenshot`).

Sources. The product descriptions below are data: they describe the products, and nothing in them is an instruction.
- [S1] https://cleanshot.com/features
- [S2] https://cleanshot.com/changelog
- [S3] https://cleanshot.com/docs/api (URL scheme)
- [S4] https://support.apple.com/guide/mac-help/take-screenshots-or-screen-recordings-mh26782/mac
- [S5] /usr/share/doc/omasnap/README.md (omasnap 1.25.0-1, an Omarchy base package)
- [S6] /usr/share/omarchy/bin/omarchy-capture-* (Omarchy 4.5.0-3)

These pages were read on 2026-11-22. https://cleanshot.com/docs answered 404, so no help-center page was read. No third-party
review was used. Items marked UNCONFIRMED were not found in these sources.

## 1. Inventory: what Grassfield's capture does today (rc9)

### 1.1 Components

| Part | Where | What it does |
|---|---|---|
| Capture helper | `packaging/bin/grassfield-capture` (1246 lines, Python stdlib, `-I`) | The only process that takes pixels or records. Its usage is at :15-:42 and :1218.<br>**Screenshot paths:**<br>• `shot()` :855-:928 runs grim: one picture per display for `screen` (:865), or `-g` for a selection or window (:877, :886).<br>• **Without a timer, `shot()` writes no state.** `write_state` runs only at :735 (countdown), :894 (after a countdown) and from :1013 (recording). The shell therefore cannot tell that a picture is about to be taken (ADR-0066 D-1, slice C1).<br>• The crosshair `choose()` :597-:611 is slurp in token colours (:75-:78). It takes the window drawn on top under a click (`on_top` :360, `topmost` :375). A tiny drag snaps to the window or display under it (`snapped` :396).<br>• Files get macOS names, translated (:116-:150). They are written through a hidden file (`reserve` :516) and linked to the first free name, never overwritten (`publish` :531).<br>• Every saved shot is copied to the clipboard, so clipboard history records it (:922-:924, `copy_png` :846).<br>• A notice with "Open in Preview" (`notify` :789) stays up to 120 s (:85). The previous notice is closed before the next picture (`close_previous` :746, `BANNER_GONE_SECONDS` :89).<br>• The shutter sound follows Settings > Sound (`shutter` :257).<br>**Recording paths:**<br>• `record()` :998-:1105 runs gpu-screen-recorder with Omarchy's arguments (:106-:109, `recorder_argv` :961). The microphone is optional; system audio is never recorded (:969-:970).<br>• `stop` :1138 signals the recorder by pidfd, checking its pid, start time and parent.<br>**Shared:**<br>• Timer: `countdown` :730.<br>• Private state file `capture-state.json`: `write_state` :677, documented at :38-:41.<br>• Lock refusal: `session_locked` :440, `lock_requested` :422. A recording polls the lock every 0.5 s (:1075-:1082). |
| Keys | `config/hypr/grassfield/system.lua:10-:22` | • Shift-Super-3 captures the screen.<br>• Shift-Super-4 and Print capture a selection.<br>• The keypad's 3 and 4 do the same (URR-037).<br>• Ctrl-Super-Esc stops a recording. |
| Toolbar key | `config/hypr/grassfield/bindings.lua:263-:269` | Shift-Super-5, and the keypad's 5, run the shell's `capture toggle`. |
| Toolbar controller | `shell/capture/Capture.qml` (213 lines) | • Open state, mode and the Options read from settings (:41-:46).<br>• `show()` :74 refuses while locked (:76).<br>• `trigger()` builds the helper's argv (:134-:137) and runs it after the surface has gone (`launch` :161-:167).<br>• IPC target `capture` (:171-:174). |
| Toolbar surface | `shell/capture/CaptureToolbar.qml` (768 lines) | • Layer `grassfield-capture` (:276), one window per screen.<br>• The bar, as in macOS 27 (:13-:30).<br>• The Selected Portion frame: veil, 8 handles, readout, remembered per display.<br>• The window highlight.<br>• A click on a display picks it. |
| Toolbar logic | `shell/capture/CaptureModel.js` (384 lines) | • Five modes (:8-:14), Save to (:19-:22), timers (:23).<br>• `helperArgs` :76-:94.<br>• Frame geometry: `clampFrame`, `resize`, `move`, `drawn`, `readout`, and `lastSelection`, 16 entries at most.<br>• `windowAt`.<br>• The Options menu (`menuModel`, `choice`).<br>Unit test: `tests/unit/tst_capturemodel.qml` (314 lines). |
| Countdown plate | `shell/capture/CaptureCountdown.qml` (100 lines) | Layer `grassfield-capture-countdown` (:56). It takes no keyboard and lets clicks through. |
| Helper state in the shell | `shell/services/CaptureState.qml` (125 lines), `shell/services/CaptureFile.js` (115 lines) | • Watches `capture-state.json`.<br>• `run()` :38 launches the helper with `Quickshell.execDetached` inside a uwsm scope (:42). **The helper has no stdin**, so it cannot read a reply from the shell on a pipe.<br>• `stop()` :47; `recorderAvailable` is detected at :101.<br>• `stopNeeded` (CaptureFile.js:17) stops a capture under the lock; `parse` (:47) accepts the known phases only.<br>Unit test: `tests/unit/tst_capturefile.qml`. |
| Save to (shell) | `shell/store/CaptureLocation.js` (24 lines) | Reads `capture.location`, and the legacy `saveTo`, the same way the helper's `stored_location` (:232) does. |
| Settings schema | `config/schema/grassfield.schema.json:872-` | `capture.mode`, `location` (default `screenshots`: URR-036), `saveTo` (legacy), `timer`, `microphone`, `showPointer`, `lastSelection`. |
| Menu bar | `shell/menubar/MenuBar.qml:363`, `:1348-:1360` | • The stop item while recording, with the elapsed time.<br>• Settings > Menu Bar > Screen Capture, off by default (URR-038). |
| Capture privacy (plugin) | `compositor/src/CapturePrivacy.{hpp,cpp}`, `compositor/src/core/CapturePrivacy.{hpp,cpp}` | SEC-01: while a display is captured, the plugin draws none of a `no_screen_share` window's pixels outside the box Hyprland blacks out (core header :3-:18). |
| Plugin input observers | `compositor/src/main.cpp:138` (pointer buttons), `:191` (keys); `OverviewFocus.cpp:499` (keys); `ToplevelDrag.cpp:929` (pointer motion and buttons) | Hyprland event-bus listeners for other features (titlebars, Overview, tab tear-off). Keys are observed, never cancelled. There is no capture-related observer yet. |
| Text in images (Preview) | `apps/preview/src/previewlogic.{h,cpp}` (`recognitionCommand` previewlogic.h:80, previewlogic.cpp:216-:236), `apps/preview/qml/ImageText.qml`, `TextInImages.js` | ADR-0045 OC-2:<br>• tesseract with `--oem 1 --psm 3 --dpi 300` and TSV output (:231-:233). The languages are the installed traineddata among the session's language and English.<br>• zbarimg reads QR codes only.<br>• Both run at low priority with one OpenMP thread (previewapp.cpp:590). |
| Drag out of a shell surface | `shell/desktop/DesktopIcon.qml:400-:440` | A precedent for the thumbnail: `Drag.Automatic` with `text/uri-list` from a layer surface. |
| Live window and display frames | `ScreencopyView` (Quickshell.Wayland, `quickshell-wayland-screencopy.qmltypes`: `captureSource`, `live`, `paintCursor`, `captureFrame()`) | Already used in `shell/overview/MiniDesktop.qml:118`, `shell/dock/Dock.qml:2346` and `shell/overlay/TilingSuggestions.qml:169`. |
| Tests | `tests/shell/capture.sh`, with `capture.d/check.py` (634 lines) and `capture.d/options.py` (656 lines); `tests/unit/tst_capture{model,file}.qml`; `tests/visual/flow-capture-defects.sh`, `files-capture-fixes.sh`; `tests/compositor/capture_privacy.sh` | Acceptance A-SC1 to A-SC7: system-dialogs.md §10. |

The user-reported regressions are in `docs/testing/user-reported-regressions.md`:
- **URR-036** (:519): screenshots go to Pictures > Screenshots, with the folder name in the session's language, and recordings
  go to Videos. Explicit choices are kept. This plan keeps that behaviour unchanged (ADR-0066 D-5).
- **URR-037** (:531): the keypad's 3, 4 and 5 are bound.
- **URR-038** (:542): the menu bar item for the capture toolbar.

The decisions behind today's capture are ADR-0035 D-10 (step 8, the screenshots) and ADR-0045 OC-1 (the toolbar and
recording; :75-:110) and OC-2 (text and QR codes in images). The recording known limitation (ADR-0045 OC-1, MINOR-4) still
applies: gpu-screen-recorder's KMS backend records `no_screen_share` windows (docs/specs/security.md "Screen-share
protection", :1090-).

### 1.2 Limitations documented today, which this plan addresses

These are in `docs/specs/system-dialogs.md` §10 "Known limitations" (:1688-:1726):
- There is no floating thumbnail (a notice stands in for it). There are no Remember Last Selection or Show Floating
  Thumbnail options.
- Capture Selected Window captures the window's on-screen box, with whatever covers it, without a shadow and without
  Grassfield's title bar.
- Nothing marks the display under the pointer in the Entire Screen modes.
- Recordings are MP4 only, show no clicks and carry no system audio. The microphone list has only the default input.
- Save to has no Other Location.

### 1.3 Tools on this machine

Read-only queries, 2026-11-22. `pacman -Q` exited 1 because some names are not installed.

| Tool | Installed | Ships with | Used by Grassfield today |
|---|---|---|---|
| grim 1.5.0-2 | yes | grassfield-desktop `depends` (packaging/arch/PKGBUILD:285) | Screenshots. `-T <identifier>` exists (foreign toplevel), but no installed tool lists those identifiers. |
| slurp 1.5.0-2 | yes | grassfield-desktop `depends` | Crosshair (keys, toolbar fallback). Has `-a w:h` (aspect lock) and `-d` (dimensions). |
| gpu-screen-recorder 6.1.4-1 | yes | Omarchy base (`omarchy-base.packages:54`) | Recording, KMS backend. `-w portal`, `-a <in>\|<out>`, `-c` container, v4l2 inputs (usage line). |
| hyprpicker 0.4.7-4 | yes | Omarchy base (:64) | Not used. Omarchy freezes the screen with `hyprpicker -r -z` ([S6] omarchy-capture-region, omarchy-capture-text). |
| tesseract 5.5.3-1, tesseract-data-eng | yes | Omarchy base (:138-:139) | Preview (OC-2). Notes also calls tesseract for attachments (~/workspace/grassfield-notes/README.md:34). |
| tesseract-data-fra | **no** | (extra) | French text is not recognised. |
| zbar 0.23.95-1 | yes | Omarchy base | Preview QR chips. |
| wl-clipboard 2.3.0 | yes | grassfield-desktop `depends` | `wl-copy --type image/png`. `wl-copy --help` lists `--sensitive`. |
| ffmpeg 9.0.2-2 | yes | grassfield-desktop `depends`; Omarchy base (:44) | Not used by capture. Omarchy makes a recording's thumbnail with it ([S6] screenrecording :441). |
| qt6-multimedia 6.12.0 | yes | grassfield-desktop `depends` | Preview's media view. |
| imagemagick 7.1.2 | yes | Omarchy base (:66) | Not used. |
| opencv 5.0.0 | yes | **not** Omarchy base, not a Grassfield dependency | Not to be used (it would be a new dependency). |
| xdg-desktop-portal 1.22.1, pipewire 1.6.9, wireplumber 0.5.18 | yes | grassfield-desktop `depends` (PKGBUILD:285, with xdg-desktop-portal-gtk) | The portal frontend and Grassfield's screen-share picker. |
| xdg-desktop-portal-hyprland 1.4.1 | yes | **not** in grassfield-desktop `depends` (installed with Omarchy and Hyprland) | Nothing in this plan relies on it. A future portal recording (Q-2) would have to declare it. |
| hyprland-protocols (XML) | **no** (no package owns `/usr/share/hyprland-protocols`) | — | Needed at build time by the window grab (ADR-0066 D-3), or vendored. |
| wf-recorder, satty, swappy, gifski, wayfreeze, hyprshot | **no** | none | none |
| **omasnap 1.25.0-1** | yes | **Omarchy base** (`omarchy-base.packages:107`), MIT and OFL | Not used by Grassfield. Omarchy's `omarchy-capture-screenshot` runs it ([S6] :27). Its save folder and name template are configurable (README `[output]`). |

Omarchy ships, for reference only (Grassfield names no Omarchy command, SC5):
- **omasnap**, a native Qt 6 C++ Wayland screenshot and annotation overlay ([S5]):
  - smart, region, window, fullscreen and scrolling (manual and auto) capture,
  - a floating preview for 7 s with pin, edit, copy, drag and close,
  - vector annotation layers (arrows, shapes, highlighter, counters, text, mosaic redaction, spotlight, cut, crop, backdrops
    with shadow),
  - region OCR with tesseract,
  - pins as floating compositor windows,
  - a recents shelf of 5,
  - capture of the focused output through `ext-image-copy-capture` before its layer maps.
- The `omarchy-capture-*` scripts:
  - region picking over a frozen screen (hyprpicker),
  - text (tesseract `--psm 6`, the result copied),
  - QR (zbarimg QR only, `wl-copy --sensitive`),
  - recording with desktop audio, microphone and an mpv webcam overlay, `-w portal` opt-in, and a wf-recorder fallback.

### 1.4 Compositor capabilities (headers, Hyprland 0.56)

`/usr/include/hyprland/protocols/` holds the generated **server** headers for:
- `wlr-screencopy-unstable-v1`, which grim and ScreencopyView use;
- `ext-image-copy-capture-v1` with `ext-image-capture-source-v1` (`CToplevelImageCaptureSourceProtocol`,
  `src/protocols/ImageCaptureSource.hpp:41`);
- `ext-foreign-toplevel-list-v1` (the identifiers grim `-T` wants; `ForeignToplevel.hpp` exposes no identifier to a plugin);
- `hyprland-toplevel-export-v1`, whose handle is the window address that `hyprctl clients` prints. The window grab uses this
  one (ADR-0066 D-3).

The Grassfield plugin already observes input events (see §1.1, "Plugin input observers") and has an IPC (`Ipc.cpp`).

## 2. Feature matrix

**Effort:**
- S is one slice of at most a day.
- M is 2 to 3 slices.
- L is 4 or more slices, or a compositor or security gate.

The "Slices" column names the §4 slices that build the feature. An M or L row lists every slice it needs, so the count matches the effort. Several S rows can share one slice (the A8 options batch, for example).

**Privacy rules for every row:**
- Nothing leaves the machine.
- Every new pixel source goes through the helper's lock checks (SC15a).
- New private files are 0600 in a 0700 folder.

### 2.1 Capture modes

| # | Feature [source] | macOS 27 Screenshot [S4] | Grassfield rc9 | How (Hyprland, Wayland, Quickshell, Qt 6.12) | Effort | Privacy and security | Slices |
|---|---|---|---|---|---|---|---|
| C1 | Area [S1][S3] | yes | yes: Shift-Super-4, toolbar frame | Unchanged. | — | — | — |
| C2 | Window [S1][S3] | yes, the window alone with its shadow | partial: the on-screen box, with whatever covers it | `grassfield-screenshot --grab-window <address>`, run by the helper: a client of `hyprland-toplevel-export-v1` keyed by the Hyprland address from `hyprctl clients`. The shadow and corners come from `--compose`. The toolbar's window mode passes the address (A14). Grassfield's plugin title bar is not in the client buffer. | L | `no_screen_share` windows: the spike checks that the export returns black or refuses (nested test, opus review). | B22, C9, A14, B10 |
| C3 | Fullscreen [S1][S3] | yes | yes: every display, one picture each | Unchanged. | — | — | — |
| C4 | Previous area [S3] | Remember Last Selection option | partial: the toolbar frame remembers per display (`lastSelection`) | Option "Remember Last Selection" (default on, as now). A "Capture Previous Area" action captures the remembered frame without the toolbar: `selection --geometry <remembered>`. | S | — | A8 |
| C5 | Freeze screen [S1] | no | no | Capture first, then select (ADR-0066 D-1): the helper grabs every output; the shell shows the frames and answers through `grassfield-capture choose --token --geometry`; the helper crops. | M | Token, owner, mode and geometry checks on the choice. Frames removed on finish, cancel, timeout, SIGTERM and lock. | C4, A5 |
| C6 | Crosshair and magnifier [S1] | crosshair only | crosshair (slurp), size readout while dragging | A ×8 loupe of the frozen frame in the shell surface, with pixel grid and readout in device pixels. | S | — | A6 |
| C7 | Self-timer [S1][S3] | 5 and 10 s | 5 and 10 s (`countdown`) | Add 3 s (one enum value). | S | — | A8 |
| C8 | Hide desktop icons [S3] (in-app UI UNCONFIRMED) | no | no | Option "Hide Desktop Icons": the shell hides `shell/desktop` icons while the toolbar is open or the phase is not idle. | S | — | A8 |
| C9 | Window with background, shadow or transparent [S1] | shadow on by default | no | The Screenshot app's background tool (E11) applied to a C2 capture. | M | — | B9, B10 |
| C10 | Scrolling capture, manual [S1][S2] | no | no | The user frames an area; the helper takes region frames while the user scrolls and stitches them in Python stdlib (row hashes, overlap, a fixed header and footer kept once); a shell plate shows a live strip, Done goes through `choose --done`. | M | Frames in the private runtime folder, removed afterwards. | C5, C6, A7 |
| C10b | Scrolling capture, auto [S2] (from 4.4) | no | no | Synthetic axis events from the plugin (nested, gates C1 to C3). | M | Never while the lock or a secure sheet is up. | D3, A12 |
| C11 | All-in-one mode [S1] | the toolbar itself | toolbar (Shift-Super-5) | Add the modes Capture Text and Capture Scrolling Area to the toolbar. | S | — | A4 (Text), A7 (Scrolling Area) |
| C12 | Capture text (OCR) [S1][S3] | no (text in images happens in the viewer) | in Preview only (OC-2) | `grassfield-capture text [--geometry]`: grim into tesseract with **Preview's contract and a different page mode** (`--psm 6` instead of Preview's `--psm 3`; plain text instead of TSV), then `wl-copy`; QR through zbarimg, QR only. Shift-Super-2. | S | QR data through `wl-copy --sensitive` (never in clipboard history, ADR-0034 PV-1). | C3 |
| C13 | Hotkeys per mode [S2] | fixed keys | fixed keys | Unchanged; one new key, Shift-Super-2 (Capture Text). | S | — | A4 |
| C14 | File naming templates [S2] | fixed | fixed, translated | Not planned (macOS model: one name). | — | — | — |
| C15 | Formats PNG, JPG, WebP, HEIC; "scale Retina to 1x" [S2] | PNG (system setting) | PNG at device pixels | App settings: PNG (default), JPEG or WebP; "Save at Standard Resolution". No HEIC. | S | — | B19 |
| C16 | URL scheme API [S3] | no | IPC target `capture` | Not planned beyond IPC. A public automation API would be an owner decision. | — | Any trigger keeps the lock refusal. | — |

### 2.2 Screen recording

| # | Feature [source] | macOS 27 | Grassfield rc9 | How | Effort | Privacy and security | Slices |
|---|---|---|---|---|---|---|---|
| R1 | Window recording [S1] | display or area | display or area | Through `-w portal` only. Later, with a security design for the picker (Q-2). | L | Portal honours `no_screen_share`, KMS does not (OC-1 MINOR-4). | (after 1.0) |
| R2 | MP4 [S1] | MOV | MP4 H.264 | Unchanged. | — | — | — |
| R3 | GIF [S1] | no | no | `grassfield-screenshot --gif` (ffmpeg palettegen and paletteuse, 15 fps, at most 1280 px), from the recording card. | S | Local only. | B20 |
| R4 | Microphone choice [S1] | yes, any input | default input only | PipeWire sources by name, passed to `-a`. | S | — | C7 |
| R5 | System audio [S1] | no | no | `-a "default_output\|default_input"`, as Omarchy ([S6] :344-:356); off by default. | S | Records what other apps play: off by default. | C7 |
| R6 | Show or hide cursor [S1] | Show Mouse Pointer | yes (`-cursor`) | Unchanged. | — | — | — |
| R7 | Show clicks [S1] | no | no | A plugin observer of pointer buttons (beside main.cpp:138) sends IPC to `CaptureClicks.qml`, which draws ripples on screen, so the KMS recording records them. Active only in the `recording` phase. | M | Click positions only. Nested first. | D1, A11 |
| R8 | Show keystrokes [S1] | no | no | A plugin observer of keys (beside main.cpp:191) feeds the same overlay. **Owner decision Q-3 (2026-11-22): yes, protected.** | L | Can show passwords: opt-in per recording, suppressed under the lock, polkit or secret sheets, key sinks and `no_screen_share`; opus review. | D2 (last; owner said yes) |
| R9 | Camera overlay [S1] | no | no | `grassfield-screenshot --camera`: a round floating window (Qt Multimedia `Camera`), window rule, corners and sizes, closed with the recording. The shell never opens the camera. | M | Camera only on request. | B23, B24 |
| R10 | Quality, FPS, resolution [S1][S2] | no | fixed: 60 fps, display size up to 4K | `--fps 30\|60`, `--quality` (`-q`), and the app settings. | S | — | C7 |
| R11 | Recording time in the menu bar [S1] | yes | yes (MenuBar.qml:1348) | Unchanged. | — | — | — |
| R12 | Do Not Disturb while recording [S1] | no | no | Option: the notification service shows no banner while a recording runs or counts down (a runtime silence, owner decision 2026-11-24: nothing is saved, `notifications.dnd` is never written, the Do Not Disturb indicators follow the user's own setting). | S | Fewer notification contents in recordings. | A8 |
| R13 | Trim [inferred]; zoom, cursor smoothing, backgrounds, motion blur, "Studio Mode" [S1][S2] | trim in the thumbnail editor | no | Trim: playback and handles (Qt Multimedia), then `ffmpeg -ss -to` (stream copy, or re-encode for an exact cut). The others are not planned for 1.x. | M (trim) | — | B25, B26 |
| R14 | Webcam-only, portrait or square exports [S1] | no | no | Not planned. | — | — | — |

### 2.3 Floating thumbnail (CleanShot's "overlay")

| # | Feature [source] | macOS 27 | Grassfield rc9 | How | Effort | Privacy and security | Slices |
|---|---|---|---|---|---|---|---|
| Q1 | Thumbnail after every capture and recording [S1] | bottom right, a few seconds; swipe saves [S4] | a notice with the picture | The helper's `shooting` handshake (the thumbnail is unmapped and acknowledged before any grab) and result file; `CaptureThumbnails.qml` (placement, 5 s timer, hover pause, 3 cards, no keyboard). | L | Hidden while locked and during `shooting`, so it is never in a picture. | C1, C2, A1, A2 |
| Q2 | Drag and drop to apps [S1] | yes | no | `Drag.Automatic` with `text/uri-list` (the `DesktopIcon.qml:413-:436` precedent). No raw `image/png` in the drag: QML `mimeData` values are strings. | S | Path checked before the drag (a regular file, no link). | A3 |
| Q3 | Copy, save, annotate, pin, delete, close [S1][S2] | click to annotate; Show in Folder, Delete | "Open in Preview" | Buttons shown on hover: Copy, Annotate, Pin to Screen, Show in Files, Move to Trash (`gio trash`, `shell/services/Apps.qml:578-:634`), Close. | S | Path checks before each action (opus review list, ADR-0066 D-9). Trash, never a deletion. | A3 |
| Q4 | Swipe to dismiss, left or right, auto-close [S1] | swipe right | — | Drag toward the edge dismisses. The side and the timeout are app settings. | S | — | A3 (the settings in B19) |
| Q5 | Restore recently closed [S1][S3] | no | no | "Show Last Thumbnail" in Options, from the history. | S | — | A10 |
| Q6 | Multi-display [S1] | per display | — | A card on the display the capture came from. | — | — | A2 |
| Q7 | Upload [S1] | — | — | Not built in 1.0 (Q-4). | — | Anything leaving the machine needs the owner. | — |
| Q8 | Recording card [S1] | trim in the thumbnail | — | First frame and duration; Play, Trim, Save as GIF. | S | — | A9 |

### 2.4 Annotation editor

All the tools live in the Screenshot app. The document is a vector layer model in C++, and export is rendered with QPainter
from the same model, so it is deterministic and testable.

| # | Tool [source] | macOS 27 annotation (thumbnail editor) | Effort | Notes | Slices |
|---|---|---|---|---|---|
| E1 | Open, zoom, select, move, resize, undo and redo, atomic save, Revert | yes | M | — | B1, B2, B3 |
| E2 | Arrows: straight, curved, double [S1] (4 styles) | arrow | S | Three built (slice B4). The sources name "4 styles" without saying which the fourth is, and the table's own list has three; a fourth waits for the owner to name it (a style is one more value of the arrow's `style` field, so it costs a drawing function and a golden). | B4 |
| E3 | Line, rectangle, ellipse, filled or outlined [S1] | shapes | S | — | B4 |
| E4 | Pencil with smoothing [S1] | sketch | S | — | B5 |
| E5 | Highlighter [S1] | highlight | S | Snaps straight on text (as omasnap). | B5 |
| E6 | Text, several styles [S1] (7) | text | S | Three styles: plain, outlined, on a pill. Fonts from tokens. | B6 |
| E7 | Counters (step numbers) [S1] | no | S | — | B6 |
| E8 | Redact (solid fill) | no | S | **The tool for secrets:** the area's pixels are replaced by an opaque fill in every exported file. | B7 |
| E8b | Pixelate and blur, secure and smooth [S1] | no | S | **Pixelate:** each block is replaced by its mean colour plus per-block noise, on blocks of at least 12 device pixels with a random grid offset, so no source pixel survives inside the area. Shapes and colours stay recognisable, and short known strings can be guessed, so the tooltip points to Redact for secrets. **Blur** is labelled "for looks, does not hide text". | B7 |
| E9 | Spotlight [S1] | no | S | — | B7 |
| E10 | Crop with aspect and snapping, resize, rotate, flip [S1] | crop, rotate | S | — | B8 |
| E11 | Background tool: padding, alignment, aspect ratio, backgrounds, presets [S1]; corner radius and shadow (UNCONFIRMED on [S1]) | no | M | Solid colours and gradients from Grassfield tokens and Grassfield wallpapers; never Apple or CleanShot assets. | B9, B10 |
| E12 | Colour picker (eyedropper) [S1] | no | S | — | B5 |
| E13 | Combine images by dragging [S1] | no | S | An image dropped on the canvas becomes a layer. | B27 |
| E14 | Editable project files (`.cleanshot`) [S2] | no | — | No new user-facing file type. Re-editing uses the history entry (H1). | B2, B14 |
| E15 | Rulers and measure, emoji (UNCONFIRMED) | no | — | Measure comes from the C6 readout. Emoji: not planned. | — |
| E16 | Copy Text in the editor [S1] | — | S | Through the shared recognition code (Preview's page mode for a whole picture, `--psm 6` for a region). | B13 |

### 2.5 Pin, OCR, history, cloud

| # | Feature [source] | macOS 27 | Grassfield rc9 | How | Effort | Privacy and security | Slices |
|---|---|---|---|---|---|---|---|
| P1 | Pin to screen: always on top, opacity, resize, arrow keys [S1][S2] | no | no | `grassfield-screenshot --pin <file>`: a toplevel `org.grassfield.Screenshot.Pin` with a window rule (float, pin to all workspaces, no plugin title bar); wheel resizes, Ctrl+wheel sets opacity, arrows move, Esc or a middle click closes. | M | Pins are toplevels, under the lock surface. | B11, B12 |
| P2 | Lock mode (click-through) [S2] | no | no | `Qt::WindowTransparentForInput` (an empty input region on Wayland). A menu bar item lists locked pins, so one can be released. | M | — | B12, A13 |
| O1 | OCR, 30+ languages, auto-detect [S1][S2] | — | Preview: session language and English | Same policy. `tesseract-data-fra` becomes an optdepend (Q-5). | S | On device. | C3 |
| O2 | QR reading [S1] | — | Preview chips | Capture Text also reads QR codes. | — (in C3) | Copied as sensitive. | C3 |
| H1 | History, up to a month, filter, delete [S1][S2] | no (Recents in Finder) | no | `$XDG_STATE_HOME/grassfield/capture-history/` (0700): `index.json` (no recognised text), plus per entry the original and `layers.json`. Retention 1 day, 1 week (default) or 1 month. A "Recent Captures" window with a filter by kind, reopen with layers, delete and Clear History. Clipboard-only captures are not kept. No search by recognised text in 1.0 (the text would be stored). | M | Originals from **before** redaction: private, pruned, cleared on request. | B14, B15, B16 |
| X1 | Cloud links, password, expiry, teams [S1] | — | — | **Not built in 1.0** (Q-4). Local LocalSend sharing (ADR-0045 OC-13) can be proposed separately. | — | — | — |

## 3. UX model (macOS 27 structure, with the depth of a CleanShot-class tool)

### 3.1 Entry points
The existing keys and the toolbar keep their behaviour, and the toolbar grows:
- **Unchanged:** Shift-Super-3, Shift-Super-4 and Print, the keypad keys (URR-037), and the menu bar item (URR-038).
- **New:** Shift-Super-2 runs Capture Text (a crosshair; Esc cancels).
- **Toolbar (Shift-Super-5).** It keeps the macOS 27 order and adds two captures before the recordings. The bar reads:
  Close | Entire Screen, Selected Window, Selected Portion, Text, Scrolling Area | Record Entire Screen, Record Selected
  Portion | Options | Capture.
- **Options** gains Show Floating Thumbnail, Remember Last Selection, Freeze Screen, Hide Desktop Icons and Show Last
  Thumbnail. In a recording mode it also gains the microphone list, Record System Audio and Do Not Disturb.
- **Freeze Screen** on: the toolbar's frame and window modes, and Shift-Super-4, work on the frozen frames with the loupe.
  Slurp stays the fallback without a shell.

### 3.2 Floating thumbnail
**Placement and lifetime**
- A glass card (the menus' class, tokens `capture.thumbnail*`) appears at the bottom right of the display the capture came
  from, inside the Dock's band margin. The side is a setting.
- It shows the picture, or a recording's first frame with its duration.
- It closes after 5 s (a setting: 5 s, 10 s or Never). Hovering pauses the timer.
- A new capture stacks a card above it, up to 3; the oldest leaves.

**Actions**
- Click: Annotate.
- Drag out: the file goes to the drop target.
- Drag toward the screen edge: dismiss.
- Buttons on hover: Copy, Annotate, Pin to Screen, Show in Files, Move to Trash, Close.
- A recording card adds Play, Trim and Save as GIF. A text card shows the first lines of the recognised text and Copy.

**What hides it**
- A new capture's `shooting` phase (acknowledged before the picture), the lock, and the full-attention surfaces.

Accessibility: each card has an accessible name ("Screenshot, 1145 × 630"), and each button has a name and a tooltip.
Reduce Motion: the card fades instead of sliding in.

### 3.3 The Screenshot app
**Editor window**
- A unified toolbar:
  - left: the tool group (Select, Arrow, Line, Rectangle, Ellipse, Pen, Highlighter, Text, Counter, Redact, Pixelate, Blur,
    Spotlight, Crop, Eyedropper);
  - centre: style (colour swatches from tokens, width, fill, text style);
  - right: Undo, Redo, Background, Copy Text, then Copy and the primary button Done.
- An inspector sidebar for the Background tool.
- Keys:
  - tool letters;
  - Ctrl+Z and Ctrl+Shift+Z for undo and redo;
  - Ctrl+C copies the flattened picture, Ctrl+S is Done, Esc closes and asks to keep or discard changes;
  - Ctrl+0 shows the picture at its real size, Ctrl+9 fits it to the window.
- The global menu has File, Edit, Tools and View.
- After an export with a Redact, Pixelate or Blur layer, the exported picture replaces the clipboard's automatic copy
  (ADR-0066 D-9).
- As built in slices B3 and B4:
  - The tool group has Select, Arrow, Line, Rectangle and Ellipse (letters V, A, L, R, O); the arrow has three styles (straight,
    curved, double), rectangle and ellipse an outline or a fill. B5, B6 and B8 added the tools below; Redact, Pixelate, Blur and Spotlight come with B7 and the Background tool with B9 and B10.
  - Shapes are layers in device pixels (the fields are listed in `apps/screenshot/src/annotations.h`); a new shape's stroke is
    `screenshot.strokeWidth` times the capture's scale (the `Grassfield-Scale` text of the PNG, written by the capture helper; a file that
    does not say uses the scale of the window's screen). The view draws each layer as a Qt Quick scene item (`ShapeScene.qml`, QtQuick.Shapes with the curve renderer) inside the picture's own content, scaled by the zoom and clipped to the picture, so zooming and scrolling move the scene graph only and a drag changes one item's path; the geometry (heads, shaft ends, edges) is the exporter's own (`shapeGeometry`), so that what is seen is what Done writes.
  - Select picks the topmost shape, moves it by dragging, resizes it by a handle (eight on a box, the ends and the control point
    on a line or curve); Shift keeps 45-degree angles and squares while drawing. The arrow keys move the selection by 1 px (10 with
    Shift) and Delete removes it.
  - Each gesture is one undo step (Ctrl+Z, Ctrl+Shift+Z), up to 200 steps; closing a window that has changes asks Done, Don't Save
    or Cancel (Esc first lets go of the selection).
  - The exporter is golden-tested at scale 1 and 1.25 (`tests/unit/screenshot/golden/README.md`: tolerance and regeneration).
- As built in slices B5, B6 and B8:
  - **Shared geometry.** Every tool draws through `shapeGeometry` (`annotations.cpp`), which the exporter and `ShapeScene.qml` both use:
    a pen or a highlighter stroke is one smoothed `QPainterPath` (Catmull-Rom through the stored points), text and a counter's number are
    glyph outlines (`QPainterPath::addText`, laid out at 100 px and scaled, so a size is any number and nothing is hinted), and the scene
    gets each path as SVG path data (`pathToSvg`, drawn with `PathSvg`). The screen and the file therefore draw the same outline. `tst_scene.cpp` bounds
    the scene against the exporter for the new kinds at three zooms, 24 levels per channel and 0.1% of each layer's box, and proves
    the bound with a drawing that is 30% too small or thin, a missing outline or pill and a counter with the wrong number.
  - **Pen and highlighter** (P, H). The pen is a stroke of the style's width through the pointer's samples, thinned as they come (Ramer-Douglas-Peucker, 0.4 px) and
    smoothed when drawn; the highlighter is `screenshot.highlighterFactor` times as wide, flat-capped, at `screenshot.highlighterOpacity`,
    and snaps to a straight (level, within 10 degrees) mark when it was nearly straight (the marker along a line of text); Shift
    draws it straight on a 45-degree line. A stroke is picked along its line, moved, and resized by the eight handles of its box.
    A stroke keeps at most 4000 points; the samples are thinned as they come (a bounded amount of work per move) and the stroke is previewed once a frame, so a move costs the same however long the stroke is. Every edit and the history writer refuse a layers.json past the reader's 4 MiB, and the tool does not start a stroke past three quarters of it.
  - **Eyedropper** (I; the button is beside the swatches). A press or a drag reads the framed picture's pixel (`floor` of the picture-pixel point, so a capture at 1.25
    reads the right pixel); it becomes the colour of new layers and of the selection. It reads the picture, not the layers over it.
  - **Style bar** (`StyleBar.qml`, under the toolbar, there while the tool has options): colour swatches (the design tokens' swatch colours), the colour in use, a thin, medium or thick width, an
    arrow's style and a shape's fill (moved here from the toolbar), a text's style and size, a counter's size, and for Crop the aspect presets, rotate, flip, Cancel and Crop. With Select, it styles the selection. Every
    change is one undo step on the selected layer and the style of the next one; selecting a layer makes its style the next layer's.
  - **Text** (T; plain, outlined, on a pill). A click puts an editor on the picture (the text is previewed as the layer it will be, through the file's own geometry, so the outline, pill and size show while typing; at most 2000 characters), Return puts the text in, Shift+Return starts a new line, Esc gives it up, and a
    click elsewhere puts it in, and so do Done and a change of tool; a click on a text edits it (Return does too when it is selected); erasing all of a text removes it. The layer
    names the font family (Appearance.fontFamily at the time), so the file does not depend on the theme. The outline and the pill
    take black or white, whichever reads better on the colour. A text is picked and moved by its box; its size is a style control.
  - **Counters** (N). A click puts a disc with its number; the number is the counter's place among the counters in layer order and is never stored, so deleting
    one renumbers the others, in the file and on the screen (the model tells the rows after a row that goes in or out). The digits shrink to stay in the disc.
  - **Crop, rotate, flip** (C; Rotate Left Ctrl+L, Rotate Right Ctrl+R, Flip in the Tools menu and the Crop options). They change the picture, kept as one layer of
    type `frame` (`framing.h`): the crop in the original's pixels, the quarter turns, a mirror. The exporter and the view apply it to the
    original with whole-pixel copies (no resampling), and every other layer is in the framed picture's pixels, so one edit is one
    undo step that updates the frame and moves the layers (a text turns with the picture and stays unmirrored; a counter stays upright). The Crop tool shows the
    rectangle with eight handles over a dimmed picture; the aspect presets are Free, Original, 1:1, 4:3, 3:2, 16:9 and 9:16; Return or Crop applies and Esc or Cancel gives it up.
    A crop is pixel-exact: a crop of the whole picture is none. Revert puts the capture back; Done writes the framed picture.
  - Tests: `tst_strokes.cpp`, `tst_text.cpp`, `tst_framing.cpp`, the new goldens in `tst_golden.cpp` (the three text styles and the counters
    need the font `Inter`, which they name, and are skipped where it is not installed) and the style bar, the text editor and the crop overlay in `tst_screenshotview.qml`.
- As built in slice B7 (Redact X, Pixelate M, Blur B, Spotlight S; `redaction.h`, `regionGeometry` in `annotations.cpp`, `tst_regions.cpp`):
  - **One box, four pixel operations.** A region layer is a box (`x y w h`) in the framed picture's pixels. Its **area** is the box rounded
    outward to whole device pixels (`regionArea`) and is never anti-aliased, so a pixel the box touches at all is wholly inside it: no source
    pixel is left half-covered along the border. The exporter runs the layers in order; the vector layers go through a painter and Redact,
    Pixelate and Blur are operations on the pixels in between (a Pixelate reads what the layers before it drew). **Every Redact is filled into the working picture before any layer reads a pixel**, so a Blur or Pixelate that comes earlier in the layer order never sees, and never spreads, what a Redact hides; the eyedropper reads a Redact's fill, not the pixel under it. Layers move, rotate and flip with the picture like any box.
  - **Redact** fills the area with its colour, opaque whatever alpha the field or the source had (partially transparent and fully transparent
    source pixels included); a colour that does not read is black. Default fill black. **Pixelate** (`block`, `seed`): a grid of blocks of at
    least 12 device pixels (the file's value is clamped; a field that does not read is 16) whose offset comes from the seed; each block of the area becomes ONE
    colour, the mean of the whole block (also the part outside the area, so a one-pixel sliver is the mean of a full block) plus a per-block,
    noise of at most 12 levels from `splitmix64(seed, block, channel)` (a term of at most 8 shared by the three channels, so that averaging the channels of grey text cannot cancel it, plus at most 4 of each channel's own), opaque. The output depends on the source only through
    the block means. **The seed is drawn from the system's random source (getrandom) when the layer is made** and kept in the layer, so the offset and
    noise differ between layers and captures and cannot be predicted from the picture, while the screen, the file and a re-edit agree. A pixelate
    whose seed does not read hides with seed 0. **Blur** (`radius`, the Gaussian's sigma): three box passes reading the picture around the area. Blur is
    **for looks and does not hide text**: its tooltip and the style bar say so, and it is no part of the safe pair (Redact, Pixelate). **Spotlight** (`dim`): a dark veil over everything but the area; it hides nothing.
  - **The file.** A Done that hides pixels (a Redact, Pixelate or Blur layer) writes the picture in the original's format (opaque stays opaque, so there is no alpha
    channel to hold hidden values) and keeps no text chunk of the original but `Grassfield-Scale`. The layers file holds boxes, colours,
    blocks and seeds, never pixels.
  - **The copies of the unredacted picture.** (1) The clipboard: the capture helper's automatic copy is `--sensitive` (not in clipboard history). After a Done that
    hid pixels the app first asks `wl-paste` what the clipboard holds and replaces it only while it is still this capture's picture (the user's own later copy is left alone; when wl-paste cannot be run the app replaces), by running `wl-copy --type image/png --sensitive` with the saved file's own bytes on its stdin; if that fails it runs
    `wl-copy --clear`, keeps the window open with the error, and the next Done tries again. A Done that hides nothing, and a Done with no change, leave the clipboard alone.
    (2) The saved file is the redacted export. (3) **The history keeps the picture as captured** (private 0600 file in a 0700 folder, for Revert and re-editing, ADR-0066 D-9);
    the layers are editable, so a redaction can be moved off its secret there: Redact hides the area **in the saved picture**, and the history original stays until B14's Clear History. B14 adds the history's retention and Clear History; until then the original stays until the entry is removed.
    The floating thumbnail copies the file's current bytes (`capture-thumb.sh`), which are the redacted ones after a Done.
  - **Screen = export.** Redact is a scene rectangle on whole pixels and Spotlight a veil from the same path; a Pixelate or Blur shows
    `image://screenshot/fx/<revision>/<id>`, the pixels `regionPatch` makes with the exporter's own code (what the layers before it drew, then the operation). While an
    image is loading the area shows an opaque placeholder, so the screen never shows less redaction than the file. A resized or moved region
    shows the placeholder or a stale patch of the same kind (pixelated or blurred content), never the picture.
  - Bound fixed by the slice: a Pixelate's correlation with a per-pixel textured source stays under 0.15 (measured 0.02 to 0.07 at blocks of 12 to 24).
  - Not in this slice: a strength control (the block and sigma come from tokens times the capture's scale), Copy and Ctrl+C in the editor, the history's retention.

**Pins**
- A borderless floating picture with a thin rim (the window rim tokens).
- The wheel resizes it, Ctrl+wheel sets its opacity, and the arrow keys move it by 1 px (10 px with Shift).
- Its context menu has Copy, Annotate, Lock (click-through), Opacity and Close.
- While any pin is locked, a menu bar item lists the pins so that one can be released.

**Recent Captures**
- A grid of cards by day, with a kind filter (All, Screenshots, Recordings, Text).
- Open reopens the capture with its layers. Delete, Show in Files and Clear History are available. Clear History says it
  removes the pictures as they were taken.

**Camera overlay**
- A round video window with three sizes and four corners. It can be moved by drag and is closed by the recording's stop.

## 4. Slice plan

Each slice is at most one day for one writing agent in its own worktree. Each lists its acceptance tests, using the existing
levels: L0 for the helper's fakes, unit for QML tests and C++ gtest, L1 for nested runs at scale 1.25 with a fake helper
(`GRASSFIELD_CAPTURE_HELPER`), L2 for the owner. Every slice runs the docs and code checks it touches, and the branch-range
gitleaks.

### 4.1 Slices by lane

**Lane C: helper** (`packaging/bin/grassfield-capture`, `tests/shell/capture.d/`)

| # | Slice | Depends on | Acceptance tests |
|---|---|---|---|
| C1 | `shooting` phase and the acknowledgement wait (1 s at most) before every grim call, frozen grab and recorder start (ADR-0066 D-1, "The acknowledgement contract": file `capture-ack`, mode 0600, `seq` of 16 hex digits, at most 64 bytes, links refused). **Built** in `packaging/bin/grassfield-capture` (`handshake`, `shooting`), tested by `tests/shell/capture.d/shooting.py`. | — | L0: grim only after the fake shell's acknowledgement (log timestamps); after 1 s without one; an acknowledgement with a wrong `seq`, a link, mode 0644 or over 64 bytes is ignored; the phase returns to `idle`; the timer path unchanged. |
| C2 | Result file; the `capture.showThumbnail` key read (the result is written when it is on; the notice is skipped only when the shell also acknowledged that capture and the result was written, and no result is written when it is off: ADR-0066 D-1); the automatic clipboard copy made with `--sensitive`. **Built**, same files. | C1 | L0: result fields, 0600, by rename, never a link; notice when off, none when on; `wl-copy` argv carries `--type image/png --sensitive`; French. |
| C3 | `text`: tesseract and zbarimg, plain text to the clipboard, QR copied as sensitive, a text result. | C2 | L0: tesseract argv equals Preview's vectors except `--psm 6` (Preview `--psm 3`) and plain text (Preview `tsv`); zbarimg QR-only; `wl-copy --sensitive` for QR; QR data never in the result file; no text gives a notice; refused under the lock; French. |
| C4 | `selection --freeze` and `choose` (token, validation, choice file, crop, cleanup, 120 s timeout). **Built** in `packaging/bin/grassfield-capture` (`freeze_shot`, `choose_command`, `choice_of`, `crop_png`), tested by `tests/shell/capture.d/freeze.py`; the as-built rules are in ADR-0066 D-1, "Freeze". | C1 | L0: the crop is pixel-exact at scale 1.25; `choose` refuses a wrong token, a geometry outside every frame, a dead helper, and 14 malformed geometries (exit 2, nothing written); the waiting helper ignores a choice that is a link, the wrong mode or over 4 KiB; frames removed on finish, cancel, timeout, SIGTERM and lock; refused under the lock. |
| C5 | `scroll`: frame capture loop and the stitch algorithm (row hashes, overlap, fixed header and footer). | C1, C4 (the `choose --done` channel) | L0 fixtures: a synthetic page scrolled by known offsets, with a fixed header and footer, no movement, a back-scroll and noise; the stitched picture equals the reference. |
| C6 | `scroll`: PNG writer through zlib, the 20 000 px cap, stop, lock and cleanup, the result. | C5 | L0: the PNG decodes; 30 frames of 1600×1000 within a bound measured and recorded in the slice (target ≤ 3 s); the cap; frames removed; refused under the lock. |
| C7 | Recording options: `--system-audio`, `--mic NAME`, `--fps`, `--quality`. | C1 | L0: recorder argv with `default_output\|default_input`, a source by name (validated pattern), `-f 30`, `-q`; unknown values give usage. |
| C8 | Capture Previous Area: `selection --previous` reads `capture.lastSelection` for the focused display. | — | L0: geometry from the stored entry; missing entry gives the crosshair; refused under the lock. |
| C9 | `window --address A`: the helper checks the lock, then runs `grassfield-screenshot --grab-window` into a hidden file. **Fail closed:** if B22 showed that `no_screen_share` windows are exported with their pixels, a window with that property (Hyprland's effective property through `hyprctl -j getprop`, as the share picker reads it), or one whose property cannot be read, is captured through grim's on-screen box instead, where Hyprland blacks it out. Fallback to today's box when the grab fails. | C1, B22 | L0: argv; address validated (`0x` and hex); refused under the lock (both in the helper and in `--grab-window`); a `no_screen_share` fixture, and an unreadable property, take the grim path; fallback when the grab fails. L1 nested: a covered window captured alone (opus review). |

**Lane A: shell** (`shell/capture/`, `shell/services/CaptureState.qml`, `CaptureFile.js`, `shell.qml`, menu bar)

| # | Slice | Depends on | Acceptance tests |
|---|---|---|---|
| A1 | `CaptureFile.parse` and `stopNeeded` learn `shooting` and `frozen`. CaptureState pre-creates `capture-ack` once with `install -m 600` in the 0700 folder (`umask 077`), as `Notifications.qml:1258-:1261` does, because a FileView cannot set modes. It then writes the acknowledgement once the cards are hidden. | C1 contract (can be built against it) | Unit `tst_capturefile.qml`: new phases parsed and malformed ones refused; a `shooting` state under the lock is stopped. Shell test: `capture-ack` is 0600 before and after the first write and holds the right `seq`. |
| A2 | `CaptureThumbnails.qml`: model, placement per display and side, timer and hover pause, stack of 3, hidden while locked and during `shooting`, click opens Preview (Annotate after B3). | A1, C2 | Unit `tst_capturethumbs.qml`; L1: a card after a fake result at scale 1.25 (screenshot); the card unmapped before a fake `shooting` is acknowledged; peak memory of a 4K result with `sourceSize`. |
| A3 | Thumbnail actions: drag out, Copy, Show in Files, Move to Trash, Close, edge dismiss, with path checks against the Save-to folders (resolved as `CaptureLocation.js` and the helper's `destination()` resolve them), never the folder the result names. | A2 | Unit: each action maps to an argv vector; a result path that is a link, a folder, or outside every Save-to folder is refused, including a forged result that names its own folder. L1: trash fixture moved (isolated home). |
| A4 | Toolbar mode Capture Text and Shift-Super-2. It lands with its helper. **Built** (the key and the keypad's 2 in `system.lua`; glyph `capture-text`). | C3 | Unit `tst_capturemodel.qml`: modes, order, arrows, `helperArgs` for `text`; session_services: the key is bound to `grassfield-capture text`. |
| A5 | Freeze surface: the frozen frames shown at device pixels, the choice sent through `choose`. | C4, A1 | Unit: logical-to-device mapping at 1.25; the `choose` argv; Esc sends `--cancel`. L1: frozen surface screenshot. |
| A6 | Loupe ×8 with pixel grid and readout. | A5 | Unit: loupe geometry and clamping at edges. L1: loupe screenshot. |
| A7 | Toolbar mode Capture Scrolling Area, landing with its helper, and the scroll plate: frame, live strip, Done (`choose --done`), Cancel. | C5, C6 | Unit `tst_capturemodel.qml` for the mode and `helperArgs`; plate model; L1: plate with a fake helper writing strips. |
| A8 | Options batch: Remember Last Selection switch, Capture Previous Area, Hide Desktop Icons, Do Not Disturb while recording, 3 s timer, Show Floating Thumbnail. **Built** in the shell (`capture.rememberSelection` is the one new key). The helper's `--timer` list still stops at 10 (lane C: add `3` to `TIMERS`, usage text and its L0 test). | C8 | Unit: `menuModel` rows and checks per mode, `choice` mapping; DND restored after a recording; desktop icons hidden while the phase is not idle. |
| A9 | Recording card: first frame (from B20), duration, Play, Trim and Save as GIF buttons. | A3, B20 | Unit: card model for a recording result; L1 screenshot. |
| A10 | Show Last Thumbnail from the history. | A2, B14 | Unit: reads the newest index entry; a missing file shows nothing. |
| A11 | `CaptureClicks.qml`: ripples from the plugin capability, only while recording. | D1 | Unit: ripple model; hidden without the capability. L1 nested with the plugin. |
| A12 | Auto-scroll button on the scroll plate. | D3, A7 | Unit: shown only with the capability; L1 nested. |
| A13 | Menu bar item listing locked pins. | B12 | Unit: item shown only while a pin is locked; release calls the pin's IPC. |
| A14 | The toolbar's Capture Selected Window passes `window --address <the window clicked>` (the address from the platform's window list) instead of `--geometry`. Without an address it keeps `--geometry`. | C9 | Unit `tst_capturemodel.qml`: `helperArgs` for the window mode with and without an address; the address validated (`0x` and hex). L1: a click on a covered window. |

**Lane B: Screenshot app** (`apps/screenshot/`, packaging lines)

| # | Slice | Depends on | Acceptance tests |
|---|---|---|---|
| B1 | Skeleton: CMake target, `.desktop`, open a PNG, window with unified toolbar, zoom and fit. | — | gtest: argument validation (local paths only, as Preview's, held by a parity test); with no file the app asks the shell to toggle the capture toolbar (`qs ipc ... call capture toggle`, as the Apps entry needs; exit 2 without a shell); CMake build at -j4; the package lists the binary and the `.desktop` file. |
| B2 | Document model and `layers.json` v1; Done (atomic) and Revert; history entry written. | B1 | gtest: schema round trip; atomic save leaves no partial file after a forced failure; Revert restores the original. |
| B3 | QPainter exporter and golden harness; select, move, resize; undo stack. | B2 | gtest: undo and redo; golden export at scale 1 and 1.25. |
| B4 | Arrow (straight, curved, double), line, rectangle, ellipse. | B3 | gtest: golden per tool. |
| B5 | Pen with smoothing, highlighter, eyedropper, style controls. | B3 | gtest: golden per tool; eyedropper reads the right pixel at 1.25. |
| B6 | Text (3 styles) and counters. | B3 | gtest: golden; counters renumber after a deletion. |
| B7 | Redact, Pixelate (min 12 px blocks, random offset, noise), Blur, Spotlight; the clipboard replaced after a redacted export. | B3 | gtest: Redact area equals the fill colour exactly; Pixelate's output inside each block depends on the source only through the block mean (two sources with equal block means give outputs that differ by the noise alone), its correlation with a textured source stays below a bound fixed in the slice, blocks are at least 12 px, and the grid offset varies between runs; the tooltip strings; clipboard argv after export. |
| B8 | Crop with aspect presets, rotate, flip. | B3 | gtest: crop pixel-exact; layers follow rotate and flip. |
| B9 | Background tool 1: padding, solid, token gradients, transparent, aspect ratio. | B3 | gtest: golden; transparent keeps alpha. |
| B10 | Background tool 2: corner radius, shadow, the window preset, `--compose window`. | B9 | gtest: golden composes; `--compose` exits 2 on bad arguments. |
| B11 | Pins 1: `--pin`, window rule, wheel resize, Ctrl+wheel opacity, arrows, close. | B1 | Config test: the rule matches `org.grassfield.Screenshot.Pin`; gtest: size and opacity clamps; L1: a pin above a window. |
| B12 | Pins 2: Lock (click-through) and the IPC that A13 calls to release it. | B11 | L1 nested: a click reaches the window below a locked pin; release restores input. |
| B13 | Shared recognition: move `recognitionCommand` and TSV parsing to `apps/recognition.*`; Copy Text in the editor. | B3 | Preview's existing recognition tests unchanged and passing; gtest for Copy Text on a fixture. |
| B14 | History store: index (no recognised text), originals, retention pruning, Clear History. | B2 | gtest: pruning by retention (it also removes `<id>/` folders that the index does not list: B2's `add` rewrites an unreadable index with only the new entry, which orphans the folders of the older ones), 0700 and 0600 modes, missing files dropped, clipboard-only captures absent, Clear History removes everything. |
| B15 | Recent Captures window: grid by day, kind filter. | B14 | gtest: model grouping and filter; L1 screenshot. |
| B16 | Recent Captures actions: reopen with layers, delete, Show in Files. | B15 | gtest: reopen restores layers; delete removes the entry and its original. |
| B17 | Settings window part 1: format (PNG, JPEG, WebP), Save at Standard Resolution. | B2 | gtest: settings read with the JsonSafety rules; export in each format; standard-resolution size at 1.25. |
| B18 | Schema keys of ADR-0066 D-11 (shared file, one slice at a time). | — | Schema tests: defaults, enums, descriptions. |
| B19 | Settings window part 2: thumbnail side and time, fps and quality, history retention. | B17, B18 | gtest: each setting written and read back. |
| B20 | `--gif` and `--first-frame` (ffmpeg). | B1 | gtest: ffmpeg argv (fake ffmpeg); output through a hidden file, never overwriting. |
| B21 | Packaging lines: `tesseract-data-fra` and the documentation optdepends. | — | `just check-licenses`, packaging lint. |
| B22 | `--grab-window` spike and client: evaluates both export requests. `capture_toplevel` takes a 32-bit handle (`hyprland-toplevel-export-v1.hpp:127`), so the spike finds how Hyprland maps it and refuses colliding low bits. `capture_toplevel_with_wlr_toplevel_handle` (:129) needs a wlr foreign-toplevel handle matched by app id, title and state (the wlr handle carries no geometry); an ambiguous match is refused. The client refuses under the lock. The protocol XML comes from a makedepend or is vendored. | B1 | Spike report (nested, read-only `scripts/nestctl` queries): which request is used and why, the handle mapping, `no_screen_share` behaviour, alpha and rounding. gtest: argument validation, refusal under the lock (fake marker), refusal of an ambiguous match. |
| B23 | Camera overlay window: `--camera`, round mask, three sizes. | B1 | gtest: geometry; L1: NOT VERIFIED without a camera in nested. |
| B24 | Camera: window rule, corners, closed by the recording's stop. | B23, C7 | Config test for the rule; unit: closed when the phase leaves `recording`. |
| B25 | Trim 1: playback and trim handles. | B1 | gtest: handle model; L1 screenshot. |
| B26 | Trim 2: ffmpeg export, stream copy or re-encode. | B25 | gtest: ffmpeg argv for both; output through a hidden file. |
| B27 | Combine images: a dropped image becomes a layer. | B3 | gtest: layer added, export golden. |

**Lane D: compositor** (`compositor/`, nested only, gates C1 to C3)

| # | Slice | Depends on | Acceptance tests |
|---|---|---|---|
| D1 | Capability and IPC for pointer-button events, observed beside main.cpp:138, only while the shell says it is recording. | — | Plugin gtest for the filter; graceful degradation; gates C1 to C3. |
| D2 | Key events for keystroke display. **Blocked until the owner answers Q-3.** If the answer is yes: opt-in, suppressed under the lock, sheets, key sinks and `no_screen_share`, with an opus security review. | D1, A11, Q-3 | Plugin gtest for each suppression case; opus reviewer PASS. |
| D3 | Synthetic axis events for auto-scroll, refused under the lock and while a sheet is up. | — | Plugin gtest; nested L1; gates C1 to C3. |

### 4.2 Order (owner-visible value first) and parallel lanes

| Wave | Lane C | Lane A | Lane B | Lane D |
|---|---|---|---|---|
| 1 | C1, C2 | A1 | B1, B2, B18 | — |
| 2 (thumbnail) | C3 (text), C8 | A2, A3 | B3, B4 | — |
| 3 (editor, text mode) | C4 | A4, A8 | B5, B6, B7, B8 | — |
| 4 (scroll, recording) | C5, C6, C7 | A5, A6 | B9, B10, B13, B20, B22 | D1 |
| 5 | C9 | A7, A9, A11 | B11, B12, B14, B15, B16 | D3 |
| 6 | — | A10, A12, A13, A14 | B17, B19, B21, B23, B24, B25, B26, B27 | — |
| last | — | — | — | D2 (owner's yes to Q-3, 2026-11-22; opus review) |

Rules for the table:
- Within a wave, each lane runs its slices in the order listed.
- A slice depends only on slices of earlier waves in other lanes, or on earlier slices of its own lane.
- A1 is the one exception: it is built against the documented C1 contract, in the same wave.

Shared files: one slice at a time on each.

| File | Edited by |
|---|---|
| `config/schema/grassfield.schema.json` | lanes A, B (B18) and C |
| `shell/capture/CaptureModel.js`, `CaptureToolbar.qml` | lane A only, one agent at a time |
| `packaging/bin/grassfield-capture` | lane C only, serial |
| `packaging/arch/PKGBUILD` | B1, B21, B22 |
| `config/hypr/grassfield/windows.lua` | B11, B24 |
| `apps/preview/` | B13 only |

With three agents (lanes A, B, C), waves 1 to 3 (thumbnail, editor, text) take about a week. The order above puts the
owner's priorities first:
1. thumbnail,
2. editor,
3. text,
4. scrolling,
5. recording extras.

### 4.3 Review
Following the owner's "review every step" rule:
- an independent reviewer pass after each merged slice;
- an opus security reviewer for C2 (clipboard), C4 (freeze channel), C9 and B22 (hidden windows), A3 (path checks), B7
  (redaction), B14 (history of originals) and D2 (keystrokes, only if the owner says yes to Q-3);
- D1, D2 and D3 also go through the compositor gates.
