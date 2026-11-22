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
  - "Pin to Screen", "Capture Text", "Capture Scrolling Area", "Recent Captures".
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
| Capture helper | `packaging/bin/grassfield-capture` (1246 lines, Python stdlib, `-I`) | The only process that takes pixels or records. Its usage is at :15-:42 and :1218.<br>**Screenshot paths:**<br>• `shot()` :855-:928 runs grim: one picture per display for `screen` (:865), or `-g` for a selection or window (:877, :886).<br>• The crosshair `choose()` :597-:611 is slurp in token colours (:75-:78). It takes the window drawn on top under a click (`on_top` :360, `topmost` :375). A tiny drag snaps to the window or display under it (`snapped` :396).<br>• Files get macOS names, translated (:116-:150). They are written through a hidden file (`reserve` :516) and linked to the first free name, never overwritten (`publish` :531).<br>• The picture is copied as PNG (`copy_png` :846).<br>• A notice with "Open in Preview" (`notify` :789) stays up to 120 s (:85). The previous notice is closed before the next picture (`close_previous` :746, `BANNER_GONE_SECONDS` :89).<br>• The shutter sound follows Settings > Sound (`shutter` :257).<br>**Recording paths:**<br>• `record()` :998-:1105 runs gpu-screen-recorder with Omarchy's arguments (:106-:109, `recorder_argv` :961). The microphone is optional. System audio is never recorded (:969-:970).<br>• `stop` :1138 signals the recorder by pidfd, checking its pid, start time and parent.<br>**Shared:**<br>• Timer: `countdown` :730.<br>• Private state file `capture-state.json`: `write_state` :677, documented at :38-:41.<br>• Lock refusal: `session_locked` :440, `lock_requested` :422. A recording polls the lock every 0.5 s (:1075-:1082). |
| Keys | `config/hypr/grassfield/system.lua:10-:22` | • Shift-Super-3 captures the screen.<br>• Shift-Super-4 and Print capture a selection.<br>• The keypad's 3 and 4 do the same (URR-037).<br>• Ctrl-Super-Esc stops a recording. |
| Toolbar key | `config/hypr/grassfield/bindings.lua:263-:269` | Shift-Super-5, and the keypad's 5, run the shell's `capture toggle`. |
| Toolbar controller | `shell/capture/Capture.qml` (213 lines) | • Open state, mode and the Options read from settings (:41-:46).<br>• `show()` refuses while locked (:74).<br>• `trigger()` builds the helper's argv (:134-:137) and runs it after the surface has gone (`launch` :161-:167).<br>• IPC target `capture` (:171-:174). |
| Toolbar surface | `shell/capture/CaptureToolbar.qml` (768 lines) | • Layer `grassfield-capture` (:276), one window per screen.<br>• The bar, as in macOS 27 (:13-:30).<br>• The Selected Portion frame: veil, 8 handles, readout, remembered per display.<br>• The window highlight.<br>• A click on a display picks it. |
| Toolbar logic | `shell/capture/CaptureModel.js` (384 lines) | • Five modes (:8-:14), Save to (:19-:22), timers (:23).<br>• `helperArgs` :76-:94.<br>• Frame geometry: `clampFrame`, `resize`, `move`, `drawn`, `readout`, and `lastSelection`, 16 entries at most.<br>• `windowAt`.<br>• The Options menu (`menuModel`, `choice`).<br>Unit test: `tests/unit/tst_capturemodel.qml` (314 lines). |
| Countdown plate | `shell/capture/CaptureCountdown.qml` (100 lines) | Layer `grassfield-capture-countdown` (:56). It takes no keyboard and lets clicks through. |
| Helper state in the shell | `shell/services/CaptureState.qml` (125 lines), `shell/services/CaptureFile.js` (115 lines) | • Watches `capture-state.json`.<br>• `run()` :38 runs the helper (uwsm-app scope); `stop()` :47.<br>• `recorderAvailable` is detected at :101.<br>• `stopNeeded` (CaptureFile.js:17) stops a capture under the lock.<br>Unit test: `tests/unit/tst_capturefile.qml`. |
| Save to (shell) | `shell/store/CaptureLocation.js` (24 lines) | Reads `capture.location`, and the legacy `saveTo`, the same way the helper's `stored_location` (:232) does. |
| Settings schema | `config/schema/grassfield.schema.json:872-` | `capture.mode`, `location` (default `screenshots`: URR-036), `saveTo` (legacy), `timer`, `microphone`, `showPointer`, `lastSelection`. |
| Menu bar | `shell/menubar/MenuBar.qml:363`, `:1348-:1360` | • The stop item while recording, with the elapsed time.<br>• Settings > Menu Bar > Screen Capture, off by default (URR-038). |
| Capture privacy (plugin) | `compositor/src/CapturePrivacy.{hpp,cpp}`, `compositor/src/core/CapturePrivacy.{hpp,cpp}` | SEC-01: while a display is captured, the plugin draws none of a `no_screen_share` window's pixels outside the box Hyprland blacks out (core header :3-:18). |
| Text in images (Preview) | `apps/preview/src/previewlogic.{h,cpp}` (`recognitionCommand` previewlogic.h:80, previewlogic.cpp:216-:236), `apps/preview/qml/ImageText.qml`, `TextInImages.js` | ADR-0045 OC-2:<br>• tesseract TSV with `--oem 1 --dpi 300 --psm 3`. The languages are the installed traineddata among the session's language and English.<br>• zbarimg reads QR codes only.<br>• Both run at low priority with one OpenMP thread (previewapp.cpp:590). |
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

These are in `docs/specs/system-dialogs.md` §10 "Known limitations" (:1696-:1724):
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
| grim 1.5.0-2 | yes | grassfield-desktop `depends` (packaging/arch/PKGBUILD:285) | Screenshots. `-T <identifier>` captures a foreign toplevel (grim -h), which is not used yet. |
| slurp 1.5.0-2 | yes | grassfield-desktop `depends` | Crosshair (keys, toolbar fallback). Has `-a w:h` (aspect lock) and `-d` (dimensions). |
| gpu-screen-recorder 6.1.4-1 | yes | Omarchy base (`omarchy-base.packages:54`) | Recording, KMS backend. `-w portal`, `-a <in>\|<out>`, `-c` container, v4l2 inputs (usage line). |
| hyprpicker 0.4.7-4 | yes | Omarchy base (:64) | Not used. Omarchy freezes the screen with `hyprpicker -r -z` ([S6] omarchy-capture-region, omarchy-capture-text). |
| tesseract 5.5.3-1, tesseract-data-eng | yes | Omarchy base (:138-:139) | Preview (OC-2). Notes also calls tesseract for attachments (~/workspace/grassfield-notes/README.md:34). |
| tesseract-data-fra | **no** | (extra) | French text is not recognised. |
| zbar 0.23.95-1 | yes | Omarchy base | Preview QR chips. |
| wl-clipboard 2.3.0 | yes | grassfield-desktop `depends` | `wl-copy --type image/png`. |
| ffmpeg 9.0.2-2 | yes | grassfield-desktop `depends`; Omarchy base (:44) | Not used by capture. Omarchy makes a recording's thumbnail with it ([S6] screenrecording :441). |
| qt6-multimedia 6.12.0 | yes | grassfield-desktop `depends` | Preview's media view. |
| imagemagick 7.1.2 | yes | Omarchy base (:66) | Not used. |
| opencv 5.0.0 | yes | **not** Omarchy base, not a Grassfield dependency | Not to be used (it would be a new dependency). |
| xdg-desktop-portal-hyprland 1.4.1, pipewire 1.6.9, wireplumber 0.5.18 | yes | grassfield-desktop `depends` (portal, pipewire) | The screen-share portal (Grassfield's own picker). |
| wf-recorder, satty, swappy, gifski, wayfreeze, hyprshot | **no** | none | none |
| **omasnap 1.25.0-1** | yes | **Omarchy base** (`omarchy-base.packages:107`), MIT and OFL | Not used by Grassfield. Omarchy's `omarchy-capture-screenshot` runs it ([S6] :27). |

Omarchy ships, for reference only (Grassfield names no Omarchy command, SC5):
- **omasnap**, a native Qt 6 C++ Wayland screenshot and annotation overlay ([S5]):
  - smart, region, window, fullscreen and scrolling (manual and auto) capture,
  - a floating preview for 7 s with pin, edit, copy, drag and close,
  - vector annotation layers (arrows, shapes, highlighter, counters, text, secure redaction, spotlight, cut, crop,
    backdrops with shadow),
  - region OCR with tesseract,
  - pins as floating compositor windows,
  - a recents shelf of 5,
  - capture of the focused output through `ext-image-copy-capture` before its layer maps (no freeze needed).
- The `omarchy-capture-*` scripts:
  - region picking over a frozen screen (hyprpicker),
  - text (tesseract `--psm 6`, the result copied),
  - QR (zbarimg QR only, `wl-copy --sensitive`),
  - recording with desktop audio, microphone and an mpv webcam overlay, `-w portal` opt-in, and a wf-recorder fallback.

### 1.4 Compositor capabilities (headers, Hyprland 0.56)

`/usr/include/hyprland/protocols/` holds:
- `wlr-screencopy-unstable-v1`, which grim and ScreencopyView use,
- `ext-image-copy-capture-v1`,
- `ext-image-capture-source-v1`: `CToplevelImageCaptureSourceProtocol`, `ImageCaptureSource.hpp:41`, captures a window alone,
- `ext-foreign-toplevel-list-v1`, which gives grim `-T` its identifier,
- `hyprland-toplevel-export-v1`.

The Grassfield plugin (`compositor/src/`) has an IPC (`Ipc.cpp`) and listens to frames. It has no input-event hook today.

## 2. Feature matrix

Effort: S ≤ 1 day, M 2 to 3 days, L ≥ 4 days or a compositor or security gate. "Slice" refers to §4.

Privacy rules for every row:
- Nothing leaves the machine.
- Every new pixel source goes through the helper's lock checks (SC15a).
- New private files are 0600 in a 0700 folder.

### 2.1 Capture modes

| # | Feature [source] | macOS 27 Screenshot [S4] | Grassfield rc9 | How (Hyprland, Wayland, Quickshell, Qt 6.12) | Effort | Privacy and security | Slice |
|---|---|---|---|---|---|---|---|
| C1 | Area [S1][S3] | yes | yes: Shift-Super-4, toolbar frame | Unchanged. | — | — | — |
| C2 | Window [S1][S3] | yes, the window alone with its shadow | partial: the on-screen box, with whatever covers it | grim `-T <ext-foreign-toplevel identifier>` (the window's own buffer, nothing covering it). The shadow and transparent corners are composed by the Screenshot app (`--compose window`). Mapping a Hyprland window to its identifier is NOT VERIFIED (a spike in the slice). Grassfield's plugin title bar is not in the client buffer. | M | `no_screen_share` windows: check that the toplevel source refuses them or returns black (test, nested). | 14 |
| C3 | Fullscreen [S1][S3] | yes | yes: every display, one picture each | Unchanged. | — | — | — |
| C4 | Previous area [S3] | Remember Last Selection option | partial: the toolbar frame remembers per display (`lastSelection`) | Option "Remember Last Selection" (default on, as now). A "Capture Previous Area" action captures the remembered frame without showing the toolbar. Helper: `selection --geometry <remembered>`. | S | — | 13 |
| C5 | Freeze screen [S1] | no | no | Capture first, then select (as omasnap [S5]): the helper grabs each output with grim into `$XDG_RUNTIME_DIR/grassfield/frozen/` (0600). The shell's selection surface shows that picture at device pixels, and the helper crops the chosen rectangle from it, so the pixels are exact and nothing is grabbed twice. hyprpicker is not needed. | M | Frozen frames are private and deleted on finish, cancel, SIGTERM and lock. The surface closes on lock (existing). | 10 |
| C6 | Crosshair and magnifier [S1] | crosshair only | crosshair (slurp), size readout while dragging | A loupe in the shell surface: ×8 of the frozen picture (needs C5), pixel grid, position and size readout in device pixels. Without freeze, a live `ScreencopyView` of the output can feed it. | S after C5 | — | 10 |
| C7 | Self-timer [S1][S3] | 5 and 10 s | 5 and 10 s (`countdown`) | Unchanged. A 3 s choice is possible (one enum value). | S | — | (13) |
| C8 | Hide desktop icons [S3] (in-app UI UNCONFIRMED) | no | no | Option "Hide Desktop Icons": the shell hides `shell/desktop` icons while `capture-state` is not idle, or always while the toolbar is open. | S | — | 13 |
| C9 | Window with background, shadow or transparent [S1] | shadow on by default | no | The Screenshot app's background tool (E11) applied to a C2 capture. | M | — | 7, 14 |
| C10 | Scrolling capture [S1][S2] (auto-scroll from 4.4, horizontal from 4.8 [S2]) | no | no | Manual scroll first: the user frames an area, the helper takes region frames (grim `-t ppm -g`, at most about 8 per second) while the user scrolls, and stitches them in Python stdlib (row hashes, overlap search, a fixed header and footer kept once). The result is written as PNG through zlib, with a live strip preview on a shell plate. Auto-scroll needs injected wheel events: the plugin IPC, or a `zwlr_virtual_pointer` client. That is a later slice (nested, gates C1 to C3). | M (manual), L (auto) | Region frames go to the private runtime folder and are deleted afterwards. Auto-scroll must never inject while the lock or a secure sheet is up. | 11, 11c |
| C11 | All-in-one mode [S1] | the toolbar itself | toolbar (Shift-Super-5) | The toolbar is that mode. Add the modes Capture Text and Capture Scrolling Area to it. | S per mode | — | 9, 11 |
| C12 | Capture text (OCR) [S1][S3] | no (text in images happens in the viewer) | in Preview only (OC-2) | `grassfield-capture text [--geometry]`: grim into tesseract, using **Preview's command contract** (languages: `--list-langs` ∩ {session language, eng}, `--oem 1 --dpi 300`; `--psm 6` for a region, as Omarchy [S6] does), then `wl-copy`. QR codes through zbarimg, QR only. Toolbar mode plus Shift-Super-2 (free in Grassfield's bindings). | S | Text from a QR code is copied with `wl-copy --sensitive`, so clipboard history never records it (ADR-0034 PV-1). OCR text is a normal copy. tesseract runs at low priority. | 9 |
| C13 | Hotkeys per mode [S2] | fixed keys | fixed keys | Unchanged for 1.0.x: Grassfield binds keys in the session config. New keys: Shift-Super-2 (Capture Text). Scrolling capture is reached from the toolbar. | S | — | 9 |
| C14 | File naming templates [S2] | fixed | fixed, translated | Not planned (macOS model: one name). | — | — | — |
| C15 | Formats PNG, JPG, WebP, HEIC; "scale Retina to 1x" [S2] | PNG (system setting) | PNG at device pixels | The Screenshot app's settings: format PNG (default), JPEG or WebP (Qt imageformats, already a dependency), and "Save at Standard Resolution", which writes logical size at a 1.25 or 2 scale. No HEIC. | S | — | 16 |
| C16 | URL scheme API [S3] | no | IPC target `capture` (toggle, open, close, status) | Not planned beyond IPC. A public automation API is an owner decision (attack surface). | — | Any API that can trigger capture must keep the lock refusal. | — |

### 2.2 Screen recording

| # | Feature [source] | macOS 27 | Grassfield rc9 | How | Effort | Privacy and security | Slice |
|---|---|---|---|---|---|---|---|
| R1 | Area, window, fullscreen recording [S1] | display or area | display or area | Window recording through `-w portal` would need the portal picker (Grassfield's own). Deferred: see ADR-0066 D-6 for the portal option. | L | Portal honours `no_screen_share`, KMS does not (OC-1 MINOR-4). | (open) |
| R2 | MP4 [S1] | MOV | MP4 H.264 | Unchanged. | — | — | — |
| R3 | GIF [S1] | no | no | "Save as GIF" on the recording's thumbnail and in the app: ffmpeg (a dependency already) with palettegen and paletteuse, 15 fps, at most 1280 px wide, written through a hidden file and renamed. | S | Local only. | 12 |
| R4 | Microphone [S1] | yes, any input | default input only | Microphone list: the PipeWire sources (`wpctl` or `--list-audio-devices`) by name. | S | The menu bar recording item already shows. | 12 |
| R5 | System audio [S1] | no | no | Option "Record System Audio" (off by default): `-a "default_output\|default_input"` merged as Omarchy does ([S6] :344-:356). | S | Records what other apps play: off by default, saved per choice. | 12 |
| R6 | Show or hide cursor [S1] | Show Mouse Pointer | yes (`-cursor`) | Unchanged. | — | — | — |
| R7 | Show clicks (colour, size, animation) [S1] | no | no | A compositor plugin hook on pointer buttons sends an IPC event to a shell overlay layer that draws a ripple. The layer is on screen, so the KMS recording records it. Active only while the phase is `recording`. | M | Click positions only. Nested first (gates C1 to C3). | 16a |
| R8 | Show keystrokes [S1] | no | no | A plugin keyboard hook sends key names to the same overlay. | L | **Security:** it would show passwords typed in any app. Allowed only as a per-recording opt-in with a warning. Never while the lock, a polkit sheet or a secret sheet holds the keyboard, and never for a window with `no_screen_share`. Needs an opus reviewer PASS and an owner decision (ADR-0066 Q-3). | 16b |
| R9 | Camera overlay (position, size, shape) [S1] | no | no | `grassfield-screenshot --camera`: a round floating window (Qt Multimedia `Camera`, already a dependency) with a window rule (float, pin, no title bar), placed in a corner, three sizes. It is on screen, so it is recorded. The shell never opens the camera. | M | The camera opens only at the user's request. The camera indicator follows PipeWire and v4l2 use. | 17 |
| R10 | Quality, FPS, resolution [S1][S2] | no | fixed: 60 fps, the display's size up to 4K (Omarchy's arguments) | The Screenshot app's settings: frame rate 30 or 60, quality (gpu-screen-recorder `-q`). | S | — | 16 |
| R11 | Recording time in the menu bar [S1] | yes | yes (MenuBar.qml:1348) | Unchanged. | — | — | — |
| R12 | Do Not Disturb while recording [S1] | no | no | Option "Turn On Do Not Disturb While Recording": the shell sets `notifications.dnd` while recording and restores it afterwards. | S | Fewer notification contents in recordings: a privacy gain. | 13 |
| R13 | Video editor: trim [inferred], zoom, cursor smoothing, backgrounds, motion blur, "Studio Mode" [S1][S2] | trim in the thumbnail editor | no | Trim: the Screenshot app plays the file with Qt Multimedia, trim handles, then `ffmpeg -ss -to` (stream copy, cuts at keyframes) or a re-encode. Zoom, cursor smoothing and backgrounds are not planned for 1.x. | M (trim) | — | 18 |
| R14 | Webcam-only and portrait or square exports [S1] | no | no | Not planned. | — | — | — |

### 2.3 Floating thumbnail (CleanShot's "overlay")

| # | Feature [source] | macOS 27 | Grassfield rc9 | How | Effort | Privacy and security | Slice |
|---|---|---|---|---|---|---|---|
| Q1 | Thumbnail after every capture and recording [S1] | bottom right, a few seconds; swipe saves [S4] | a notice with the picture | `shell/capture/CaptureThumbnails.qml`: a layer at the bottom right of the display the capture came from. Glass card, tokens only. It closes after `capture.thumbnailSeconds` (5 s by default) and hovering pauses the timer. Up to 3 cards stack. It takes no keyboard focus. The helper announces each result in a private `capture-result.json`. The notice stays the fallback when the option is off. | M | Hidden while locked. Hidden as soon as a new capture starts, so it never appears in a picture (helper phase). | 1, 2 |
| Q2 | Drag and drop to apps [S1] | yes | no | `Drag.Automatic` with `text/uri-list` (the `DesktopIcon.qml:413-:436` precedent). QML `mimeData` values are strings, so no raw `image/png` in drag (limitation). | S | — | 2 |
| Q3 | Copy, save, annotate, pin, delete, close [S1][S2] | click to annotate; Show in Folder, Delete | "Open in Preview" | Buttons shown on hover: Copy, Annotate (opens the Screenshot app), Pin to Screen, Show in Files, Move to Trash (`gio trash`, as the shell already runs it, `shell/services/Apps.qml:578-:634`), Close. A recording card adds Play, Trim and Save as GIF. | S | Trash rather than delete: the file can be restored. | 3 |
| Q4 | Swipe to dismiss, position left or right, size, auto-close [S1] | swipe right | — | A drag toward the screen edge dismisses (the file is already saved). Settings in the Screenshot app: Left or Right, closes after 5 s, 10 s or Never. | S | — | 3, 16 |
| Q5 | Restore recently closed [S1][S3] | no | no | "Show Last Thumbnail" in the toolbar's Options menu, from the result history (H1). | S | — | 15 |
| Q6 | Multi-display [S1] | per display | — | A card on the display the capture came from. A screen capture of every display shows one card per picture, on the focused display. | — | — | 2 |
| Q7 | Upload [S1] | — | — | Not built (ADR-0066 D-9). | — | Anything leaving the machine needs the owner. | — |

### 2.4 Annotation editor

All the tools live in the Screenshot app. The document is a vector layer model in C++, and export is rendered with QPainter
from the same model, so it is deterministic and testable.

| # | Tool [source] | macOS 27 annotation (thumbnail editor) | Effort | Notes | Slice |
|---|---|---|---|---|---|
| E1 | Select, move, resize, undo and redo | yes | M (with the skeleton) | — | 4, 5 |
| E2 | Arrows: straight, curved, double [S1] (4 styles) | arrow | S | — | 5 |
| E3 | Line, rectangle, ellipse, filled or outlined [S1] | shapes | S | — | 5 |
| E4 | Pencil with smoothing [S1] | sketch | S | — | 5 |
| E5 | Highlighter [S1] | highlight | S | Snaps straight on text (as omasnap). | 5 |
| E6 | Text, several styles [S1] (7) | text | S | Three styles: plain, outlined, on a pill. Fonts from tokens (Inter). | 6 |
| E7 | Counters (step numbers) [S1] | no | S | — | 6 |
| E8 | Pixelate and blur, secure and smooth [S1] | no | S | **Secure** pixelate replaces each block with its mean plus noise in the flattened output, so it is irreversible. Blur alone is not offered as redaction (blurred small text can be recovered). | 6 |
| E9 | Spotlight [S1] | no | S | — | 6 |
| E10 | Crop with aspect and snapping, resize, rotate, flip [S1] | crop, rotate | S | — | 6 |
| E11 | Background tool: padding, alignment, aspect ratio, backgrounds, presets [S1]; corner radius and shadow (UNCONFIRMED on [S1]) | no | M | Backgrounds: solid colours and gradients from Grassfield tokens and Grassfield wallpapers. Never Apple or CleanShot assets. | 7 |
| E12 | Colour picker (eyedropper) [S1] | no | S | — | 5 |
| E13 | Combine images by dragging [S1] | no | M | An image dropped on the canvas becomes a layer. | (later) |
| E14 | Editable project files (`.cleanshot`) [S2] | no | S | No new user-facing file type. Re-editing uses the history entry (H1: the original plus `layers.json`). | 4, 15 |
| E15 | Rulers and measure, emoji (UNCONFIRMED) | no | — | Measure comes from the C6 readout. Emoji: not planned. | — |
| E16 | OCR inside the editor [S1] | — | S | "Copy Text" on the canvas or a region, through Preview's recognition code (shared). | 9b |

### 2.5 Pin, OCR, history, cloud

| # | Feature [source] | macOS 27 | Grassfield rc9 | How | Effort | Privacy and security | Slice |
|---|---|---|---|---|---|---|---|
| P1 | Pin to screen: always on top, opacity, resize, arrow keys [S1][S2] | no | no | `grassfield-screenshot --pin <file>`: a toplevel `org.grassfield.Screenshot.Pin` with a window rule in `config/hypr/grassfield/windows.lua` (float, pin to all workspaces, no plugin title bar). The wheel resizes, Ctrl+wheel sets opacity, arrows move, Esc or a middle click closes. | M | Pins are toplevels, so the lock covers them. | 8 |
| P2 | Lock mode (click-through) [S2] | no | no | `Qt::WindowTransparentForInput` gives an empty input region on Wayland. A menu bar item ("Pinned Pictures") releases it, because a click-through window cannot be clicked. | S | — | 8 |
| O1 | OCR, 30+ languages, auto-detect [S1][S2] | — | Preview: session language and English | Same policy. Recommend `tesseract-data-fra` as an optdepend for the owner's French (a packaging line, no new code). | S | On device. | 9 |
| O2 | QR reading [S1] | — | Preview chips | Capture Text also reads QR codes (C12). | S | Copied as sensitive. | 9 |
| H1 | History, up to a month, filter, delete [S1][S2] | no (Recents in Finder) | no | `$XDG_STATE_HOME/grassfield/capture-history/` (0700): `index.json`, plus per entry the original and `layers.json`. Retention: 1 day, 1 week (default) or 1 month. A "Recent Captures" window in the Screenshot app with a filter by kind, reopen with layers, delete and Clear History. Clipboard-only captures are **not** kept (macOS: no trace). | M | The history keeps originals from **before** redaction: private, pruned, cleared on request. The Clear History wording says so. | 15 |
| X1 | Cloud links, password, expiry, teams [S1] | — | — | **Not built.** Upload, links or any remote service is an owner decision (legal, privacy, spending, public). Local sharing by LocalSend (ADR-0045 OC-13) can be proposed separately. | — | — | — |

## 3. UX model (macOS 27 structure, with the depth of a CleanShot-class tool)

### 3.1 Entry points
The existing keys and the toolbar keep their behaviour, and the toolbar grows:
- **Unchanged:** Shift-Super-3, Shift-Super-4 and Print, the keypad keys (URR-037), and the menu bar item (URR-038).
- **New:** Shift-Super-2 runs Capture Text (a crosshair; Esc cancels).
- **Toolbar (Shift-Super-5).** It keeps the macOS 27 order and adds two captures before the recordings. The bar reads:
  Close | Entire Screen, Selected Window, Selected Portion, Text, Scrolling Area | Record Entire Screen, Record Selected
  Portion | Options | Capture.
  - The Text mode is a frame, like Selected Portion.
  - The Scrolling Area mode is a frame, then the scroll plate.
- **Options** gains Show Floating Thumbnail, Remember Last Selection, Freeze Screen and Hide Desktop Icons. In a recording
  mode it also gains the microphone list, Record System Audio and Do Not Disturb.
- **Freeze Screen** on: the toolbar's frame and window modes, and Shift-Super-4, work on the frozen picture with the loupe.
  Shift-Super-4 then uses the shell's surface instead of slurp, and slurp stays the fallback without a shell.

### 3.2 Floating thumbnail
**Placement and lifetime**
- A glass card (the menus' class, tokens `capture.thumbnail*`) appears at the bottom right of the display the capture came
  from, inside the Dock's band margin. The side is a setting.
- It shows the picture, or a recording's first frame with its duration.
- It closes after 5 s (a setting: 5 s, 10 s or Never). Hovering pauses the timer.
- A new capture stacks a card above it, up to 3; the oldest leaves.

**Actions**
- Click: Annotate.
- Drag out: the file goes to the drop target, and the card stays until the drop ends.
- Drag toward the screen edge: dismiss. The file is already saved.
- Buttons on hover (the shared `ToolButton`, glyphs from branding/icons): Copy, Annotate, Pin to Screen, Show in Files, Move
  to Trash, and Close (the circle with a cross).
- A recording card adds Play, Trim and Save as GIF.
- A text card shows the first lines of the recognised text and a Copy button.

**What hides it**
- A new capture starting (it is put away before the picture is taken), the lock, and the full-attention surfaces.

Accessibility: each card has an accessible name ("Screenshot, 1145 × 630"), and each button has a name and a tooltip.
Reduce Motion: the card fades instead of sliding in.

### 3.3 The Screenshot app
**Editor window**
- A unified toolbar:
  - left: the tool group (Select, Arrow, Line, Rectangle, Ellipse, Pen, Highlighter, Text, Counter, Pixelate, Spotlight,
    Crop, Eyedropper);
  - centre: style (colour swatches from tokens, width, fill, text style);
  - right: Undo, Redo, Background, Copy Text, then Copy and the primary button Done.
- An inspector sidebar for the Background tool: padding, background, aspect, corner radius, shadow.
- Keys:
  - tool letters (A arrow, R rectangle, T text, and so on);
  - Ctrl+Z and Ctrl+Shift+Z for undo and redo;
  - Ctrl+C copies the flattened picture, Ctrl+S is Done, Esc closes and asks to keep or discard changes;
  - Ctrl+0 shows the picture at its real size, Ctrl+9 fits it to the window.
- The global menu has File, Edit, Tools and View.

**Pins**
- A borderless floating picture with a thin rim (the window rim tokens).
- The wheel resizes it, Ctrl+wheel sets its opacity, and the arrow keys move it by 1 px (10 px with Shift).
- Its context menu has Copy, Annotate, Lock (click-through), Opacity and Close.
- While any pin is locked, a menu bar item lists the pins so that one can be released.

**Recent Captures**
- A grid of cards by day, with a kind filter (All, Screenshots, Recordings, Text) and search by recognised text when present.
- Open reopens the capture with its layers. Delete, Show in Files and Clear History are available.

**Camera overlay**
- A round video window with three sizes and four corners. It can be moved by drag and is closed by the recording's stop.

## 4. Slice plan

Each slice is at most one day for one writing agent in its own worktree. Each lists its acceptance tests, using the
existing levels: L0 for the helper's fakes, unit for QML tests and C++ gtest, L1 for nested runs at scale 1.25 with a fake
helper (`GRASSFIELD_CAPTURE_HELPER`), L2 for the owner. Every slice runs `just check-quick` and the tests it touches.

### 4.1 Order (owner-visible value first)

| # | Slice | Lane | Depends on | Acceptance tests |
|---|---|---|---|---|
| 1 | **Result channel**: the helper writes `capture-result.json` (ADR-0066 D-1). The `capture.showThumbnail` schema key; the notice is skipped when it is on. | C (helper) | — | L0: result fields, file mode 0600, written by rename, never a link; notice sent when the key is off and not when on; French; recording result; the key's default `true` in schema tests. |
| 2 | **Floating thumbnail**: `CaptureThumbnails.qml` with placement, timer, hover pause, stacking, put-away on phase change, hidden on lock, click opens Preview (until slice 4), drag out as `text/uri-list`. | A (shell) | 1 | Unit `tst_capturethumbs.qml`: stack of 3, timer and pause, put-away when the phase leaves idle, hidden while locked, position per display and side. L1: a card after a fake result, at scale 1.25, screenshot. |
| 3 | **Thumbnail actions**: Copy, Show in Files, Move to Trash (`gio trash` through the shell's helper environment), Close, dismiss toward the edge; recording card: Play. | A | 2 | Unit: an action is mapped to an argv vector, never a command line. L1: the trash fixture is gone from the folder and present in the trash (isolated home). |
| 4 | **Screenshot app skeleton**: `apps/screenshot`, CMake target, `.desktop`, opens a PNG, toolbar shell, zoom and fit, Done writes atomically, Revert, a history entry written (original and `layers.json` v1). Packaging lines. | B (app) | — | gtest: argument validation (local paths only, as Preview's), atomic save (no partial file after a forced failure), `layers.json` schema round trip. CMake build at -j4. The package lists the binary. |
| 5 | **Tools 1**: select, move, resize; arrow (straight, curved, double); line; rectangle and ellipse (outline or filled); pen with smoothing; highlighter; eyedropper; colours and widths from tokens; undo and redo. | B | 4 | gtest: model operations and undo stack; golden export PNGs per tool at scale 1 and 1.25 (pixel compare with tolerance). L1: editor screenshot. |
| 6 | **Tools 2**: text (3 styles), counters, spotlight, secure pixelate, crop with aspect presets, rotate and flip. | B | 5 | gtest: the pixelated region of the export is constant per block plus bounded noise, and its correlation with the source is below a threshold; crop is pixel-exact; counters number themselves in order after a deletion. |
| 7 | **Background tool**: padding, token gradients, solid, transparent, aspect, corner radius, shadow; the "window" preset. `--compose window`. | B | 5 | gtest: golden composes; a transparent background keeps alpha; `--compose` exits 2 on bad arguments. |
| 8 | **Pins**: `--pin`, window rule, wheel resize, opacity, arrows, lock (click-through) and the menu bar release item. | B, with the menu bar item in A | 4 | Config test: the rule matches `org.grassfield.Screenshot.Pin`. gtest: opacity and size clamps. L1: a pin above a window, locked; a click reaches the window below. |
| 9 | **Capture Text**: `grassfield-capture text`; the toolbar mode; Shift-Super-2; QR copied as sensitive; a text result for the thumbnail. | C, with the toolbar mode in A | 1 (thumbnail optional) | L0: tesseract argv equals Preview's vectors (languages, `--oem 1 --dpi 300`, `--psm 6`); zbarimg QR-only; `wl-copy --sensitive` for QR; no text gives the notice "No text found"; refused under the lock; French. Unit: `helperArgs` for the mode. session_services: the key is bound. |
| 9b | **Shared recognition**: move `recognitionCommand` and TSV parsing to `apps/recognition.*`; Copy Text in the editor. | B | 4 | Preview's existing recognition tests unchanged and passing; gtest in the app for Copy Text on a fixture. |
| 10 | **Freeze and loupe**: `selection --freeze` (grab, phase `frozen`, crop on choice); the frozen picture in the toolbar surface at device pixels; ×8 loupe with readout; the Freeze Screen option. Split into 10a (helper) and 10b (shell), each ≤ 1 day. | C, then A | — | L0: the crop is pixel-exact at scale 1.25 (logical-to-device rounding); frozen files are 0600 and removed on finish, cancel, SIGTERM and lock; refused under the lock. Unit: loupe geometry. L1: frozen surface screenshot. |
| 11 | **Scrolling capture (manual)**: `scroll --geometry`, frames, stitching, PNG through zlib (11a, helper); the scroll plate with live strip, Done and Cancel, and the toolbar mode (11b, shell). | C, then A | 1 | L0 fixtures: a synthetic page scrolled by known offsets, with a fixed header and footer, no movement, a back-scroll, and noise. The stitched output equals the reference. 30 frames of 1600×1000 stitched within a bound measured and recorded in the slice (target ≤ 3 s on the dev machine). The PNG decodes. Cap at 20 000 px. |
| 12 | **Recording extras 1**: system audio, microphone list, fps and quality, the recording card's first frame, Save as GIF. | C, with the card in A | 1, 3 | L0: recorder argv with `default_output\|default_input`; mic by name; ffmpeg argv for the first frame and the GIF (fake ffmpeg); GIF written through a hidden file, never overwriting. |
| 13 | **Options batch**: Remember Last Selection switch, Capture Previous Area, Hide Desktop Icons, Do Not Disturb while recording, 3 s timer. | A | — | Unit: `menuModel` rows and checks per mode, `choice` mapping; DND restored after a recording; desktop icons hidden while the phase is not idle. |
| 14 | **Window alone**: spike mapping a Hyprland window to its ext-foreign-toplevel identifier; `window --toplevel`; shadow through `--compose`; fallback to today's box. | C | 7 | Spike report (nested, read-only `scripts/nestctl` queries). L0: argv `grim -T`; fallback when there is no identifier. L1 nested: a covered window captured alone; a `no_screen_share` fixture stays black or is refused (security check). |
| 15 | **History**: store, retention, Recent Captures window, reopen with layers, Clear History, Show Last Thumbnail. | B, with the toolbar item in A | 4, 1 | gtest: pruning by retention, 0700 and 0600 modes, missing files dropped, clipboard-only captures absent, Clear History removes everything. Unit: Show Last Thumbnail reads the newest entry. |
| 16 | **App settings window**: format, Save at Standard Resolution, thumbnail side and time, fps and quality, history retention; schema keys (ADR-0066 D-11). | B, with the schema in A | 4 | Schema tests (defaults, enums); gtest: settings read with the JsonSafety rules (the twin of the helper's `settings_group`). |
| 16a | **Click ripples**: plugin pointer-button capability and IPC; `CaptureClicks.qml` while recording. | D (compositor), then A | 12 | Plugin gtest for the event filter (recording phase only); gates C1 to C3; the option hidden without the plugin; nested L1. |
| 16b | **Keystroke display**: built only after the owner answers Q-3 and an opus reviewer passes it. | D, with a security review | 16a, Q-3 | Suppressed under the lock, a polkit or secret sheet, a key sink and `no_screen_share`; opt-in per recording. |
| 17 | **Camera overlay**: `--camera`, window rule, sizes and corners, closed with the recording. | B | 4, 12 | gtest: size and corner geometry. L1: NOT VERIFIED without a camera in nested (a fake v4l2 source if one is available). |
| 18 | **Trim**: playback and trim handles in the app; ffmpeg cut. | B | 4, 12 | gtest: the ffmpeg argv for stream copy and for re-encode; output written through a hidden file. |
| 11c | **Auto-scroll**: plugin axis injection, never while locked or while a sheet is up. | D | 11, 16a | Plugin gtest; nested L1; gates C1 to C3. |

### 4.2 Parallel lanes
One writing agent per worktree. Where two lanes edit the same file, they serialize on it.

| Lane | Area | Slices | Shared file to watch |
|---|---|---|---|
| A | shell (`shell/capture/`, `shell.qml`, menu bar) | 2 → 3 → 13; the shell parts of 8, 9, 10b, 11b, 12, 15 | `CaptureModel.js` and `CaptureToolbar.qml`: one lane-A agent at a time. |
| B | app (`apps/screenshot/`) | 4 → 5 → 6 → 7; 8, 9b, 15, 16, 17, 18 after 4 | `apps/preview` only in 9b |
| C | helper (`packaging/bin/grassfield-capture`, `tests/shell/capture.d/`) | 1 → 9, 10a, 11a, 12, 14 | the helper is one file, so the lane is serial |
| D | compositor (`compositor/`, nested only) | 16a, then 11c and 16b | — |

Lanes A, B and C can start on day one: slice 1 in C, slice 4 in B, and slice 2 in A once 1 has landed. With three agents,
slices 1 to 9 land in about four to five working days. The owner-visible order is:
1. thumbnail (1 to 3),
2. editor (4 to 7),
3. text (9),
4. scrolling (11),
5. recording extras (12),
6. then pins, history, freeze, window alone and the plugin features.

### 4.3 Review
Following the owner's "review every step" rule:
- an independent reviewer pass after each merged slice;
- an opus security reviewer for 10 (private frames), 14 (hidden windows), 15 (history of originals) and 16b (keystrokes);
- slices 16a, 16b and 11c also go through the compositor gates.
