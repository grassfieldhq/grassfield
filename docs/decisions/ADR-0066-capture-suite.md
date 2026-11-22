# ADR-0066: The capture suite (floating thumbnail, annotation, text, scrolling capture, richer recording)
Status: Proposed · Date: 2026-11-22 · Decider: owner (scope and the open questions Q-1 to Q-6), integrator (design, merge
after review) · Number: 0066 (the next free number on every ref on 2026-11-22)

## Context
The owner asked on 2026-11-22 for a capture as rich as CleanShot X on macOS, "with all its features". Grassfield 1.0.0-rc9
ships a macOS 27 capture (ADR-0035 D-10, ADR-0045 OC-1; docs/specs/system-dialogs.md §10):
- the keys Shift-Super-3 and Shift-Super-4,
- the Shift-Super-5 toolbar, with frame, window and display picking,
- timer, Save to (by default Pictures > Screenshots: URR-036), microphone recording and the stop item.

The inventory, the feature matrix (with sources) and the slice plan are in docs/specs/capture-suite.md. The matrix shows four
kinds of missing feature:
- surfaces that do not exist yet: the floating thumbnail, an annotation editor, pins, history;
- capture modes the helper lacks: text, scrolling, freeze, a window alone;
- recording options: system audio, GIF, trim, clicks, keystrokes, camera;
- privacy questions that the current scope never raised.

Constraints:
- CLAUDE.md: no new service, dependency, language or directory without need, and an ADR when something crosses modules.
- Every capture keeps the lock rules (SC15a). Compositor changes stay nested and degrade gracefully.
- master-prompt §5.5: tokens only, no Apple or third-party names or assets in the UI.

Owner delegation (memory, "delegated decisions"): decide by "closest to macOS 27, no technical step for the end user".
Questions that involve legal, public, security, spending or irreversible matters go to the owner (§Open questions).

## Decision

### D-1. One process takes pixels: `grassfield-capture`
The helper (`packaging/bin/grassfield-capture`) stays the only process that captures the screen or records. Every lock
check (`session_locked`, the 0.5 s poll), the private state and the stop protocol therefore stay in one tested place. It
gains these subcommands and options:
- `text [--geometry G]`: recognise text and QR codes in an area (D-7).
- `selection --freeze`: freeze the screen first. The helper grabs every output with grim into `$XDG_RUNTIME_DIR/grassfield/frozen/`
  (0700 folder, 0600 files). It writes the phase `frozen` with those paths to `capture-state.json`, waits for the shell's
  choice on stdin, and crops the chosen rectangle from the grabbed picture. Pixels are exact, nothing is grabbed twice, and
  hyprpicker is not needed.
- `scroll --geometry G`: a scrolling capture. It takes region frames (`grim -t ppm -g`, at most 8 per second) until it is
  told to stop. It stitches them in Python stdlib (row hashes, overlap search, a fixed header and footer kept once, at most
  20 000 px long) and writes the PNG through zlib. Python is already the helper's language, so this needs no new binary.
  The slice's acceptance test bounds the time (§4 of the spec). The fallback, if that bound fails, is a C++ stitcher in the
  Screenshot app (D-3).
- `window --toplevel ID`: the window alone, through grim `-T` (`ext-image-capture-source-v1`'s toplevel source in Hyprland
  0.56). Mapping a Hyprland window to its ext-foreign-toplevel identifier is a spike in slice 14.
- `record ... [--system-audio] [--mic NAME] [--fps 30|60] [--quality Q]`, as described in D-6.

**The result channel.** After each capture the helper writes `$XDG_RUNTIME_DIR/grassfield/capture-result.json` (0600,
written by rename):

    {"v": 1, "id", "kind": "shot" | "recording" | "text" | "scroll", "paths": [...], "primary",
     "output", "rect", "scale", "pixels" {w, h}, "time", "text"}

- `text` holds the first 512 characters of the recognised text, never QR data.
- When `capture.showThumbnail` is true (the default), the helper does not send the notice. The shell shows the thumbnail.
- When it is false, the notice is sent as it is today, so the old behaviour stays one switch away.
- The helper still closes the previous notice before a picture. The shell hides its thumbnails as soon as the phase leaves
  `idle`, so no thumbnail appears in a picture.

### D-2. The shell owns what is on screen during and right after a capture
New shell surfaces, all in `shell/capture/` (an existing directory), each a layer with its own namespace and the
`no_anim` rule where a fade could end up in a picture:
- `CaptureThumbnails.qml`, namespace `grassfield-capture-thumbnail`: the floating thumbnail (spec §3.2). It takes no
  keyboard. A drag out offers `text/uri-list` (the DesktopIcon precedent). It is hidden while locked.
- A freeze and loupe mode in `CaptureToolbar.qml`: the frozen picture shown at device pixels (`sourceSize` in pixels, scale
  1/s), and a ×8 loupe with a readout.
- `CaptureScrollPlate.qml`: the scrolling capture's frame, Done, Cancel and a live strip preview.
- `CaptureClicks.qml` (slice 16a, only when the plugin offers the event): click ripples while recording.

The shell never decodes a full picture for a thumbnail. It sets `sourceSize` to the card's pixel size, the notice's rule
(B-19).

### D-3. The editor, pins, history and camera: a new Qt Quick app, "Screenshot"
`apps/screenshot/` (a new directory, needed for a new binary) builds `grassfield-screenshot`, app id
`org.grassfield.Screenshot`, in the `grassfield-desktop` package. That is a new binary and a `.desktop` file, not a new
package and not a new dependency. It is C++ with Qt Quick, built with CMake like `apps/preview`, and follows the shared
`Grassfield.Ui`, the unified toolbar (ADR-0015) and the global menu (ADR-0008).

| Mode | Command | What it is |
|---|---|---|
| Editor (default) | `grassfield-screenshot <file>` | The annotation window (spec §3.3). |
| Pin | `--pin <file>` | A floating picture (app id `org.grassfield.Screenshot.Pin`, window rule in `config/hypr/grassfield/windows.lua`). |
| Recent Captures | `--history` | The history window (D-5). |
| Camera | `--camera` | The camera overlay for recordings (Qt Multimedia `Camera`). |
| Compose | `--compose window <in> <out>` | Headless: the shadow and transparent corners of a window capture, used by the helper. |
| Settings | `Ctrl+,` | The app's own settings window. Advanced preferences live here, not in Settings or the toolbar. |

The document model is C++: a list of vector layers over the original picture. QML draws the layers for interaction.
Export renders the same model with QPainter at the picture's device pixels, which makes export deterministic and
golden-testable.

Code shared with Preview: `preview::recognitionCommand` and the TSV parsing move into one source file compiled into both
binaries (`apps/recognition.{h,cpp}`, beside the shared headers already in `apps/`: `appscope.h`, `textrender.h`). That is a move, not a new
abstraction: two users need it.

Why a new app:
- Preview's spec makes viewing its purpose and lists annotation as a non-goal (docs/specs/preview.md:18-:22).
- The shell must not hold editors, camera streams or minutes-long documents (shell stability; the shell unit's memory limit).
- macOS edits in a window with normal focus and a global menu.

### D-4. File formats
- **Pictures:** PNG by default, as today. The Screenshot app's settings can choose JPEG or WebP; Qt's image plugins are
  already a dependency. "Save at Standard Resolution" writes the logical size on a scaled display. No HEIC.
- **Recordings:** MP4 (H.264, the recorder's default, as today). GIF is an export made by ffmpeg (palettegen and
  paletteuse, 15 fps, at most 1280 px wide).
- **No new user-facing file type.** An editable document is a history entry: the untouched original and `layers.json`, a
  versioned schema `{"v": 1, "layers": [...]}` that the Screenshot app's unit tests validate. No new MIME registration.

### D-5. Storage (URR-036 kept)
- **Where files go is unchanged.** Pictures go where Save to says: by default Pictures > Screenshots, with the folder name in
  the session's language. Recordings go to Videos. Names, `(2)` suffixes and the hidden-file-then-link writing are
  unchanged. The keys follow `capture.location`.
- **A capture is saved at once,** as today. macOS keeps it unsaved until the thumbnail goes away. Delegated decision:
  - the keys and every older path keep working the same, and a crash or logout never loses a capture;
  - the thumbnail's Move to Trash undoes a save without a technical step (the file can be restored).
- **Annotate.** Done replaces the file atomically (hidden file, then rename) and keeps the original in the history for
  Revert. "Save as Copy" writes `<name> (edited).png` beside it.
- **History:** `$XDG_STATE_HOME/grassfield/capture-history/` (0700, files 0600):
  - `index.json`, plus per entry `original.png` and `layers.json`;
  - retention 1 day, 1 week (default) or 1 month; pruned at each capture and at app start; Clear History removes everything;
  - an entry whose file is gone is dropped;
  - clipboard-only captures are never kept.
- **Temporary frames** (freeze, scroll): `$XDG_RUNTIME_DIR/grassfield/` (tmpfs, 0700). They are removed on finish, cancel,
  SIGTERM and lock. A left-over folder is removed at the next helper start.

### D-6. The recording pipeline
- **Kept:** gpu-screen-recorder with the KMS backend and Omarchy's arguments (OC-1), plus the stop, lock and pidfd
  protocol.
- **Added options:**
  - system audio (`-a default_output`, merged with the microphone by `|`, as Omarchy does; off by default);
  - a choice of microphone (PipeWire sources by name);
  - 30 or 60 fps and a quality setting (`-q`).
- **After recording:**
  - the thumbnail card shows the first frame (ffmpeg, as Omarchy makes its preview);
  - Save as GIF and Trim (Qt Multimedia playback, ffmpeg `-ss/-to`, stream copy, a re-encode when the cut must be exact).
- **Do Not Disturb while recording,** as an option.
- **Not changed here:** the portal backend (`-w portal`) would honour `no_screen_share` and allow window recording, but it
  goes through Grassfield's screen-share picker. Pre-answering that picker from the helper would make a channel that could
  bypass it. That is security design, so it is asked as Q-2 and not decided here.

### D-7. Text recognition: tesseract and zbar, Preview's contract
Notes and Preview already run the tesseract CLI (Omarchy base packages). The suite uses the same tool, and the same
**command contract** as Preview (OC-2):
- languages: `tesseract --list-langs` ∩ {the session's language, eng};
- `--oem 1 --dpi 300`;
- `--psm 6` for an area (Omarchy's choice for a region; Preview keeps `--psm 3` for a whole page);
- lowest CPU priority, one OpenMP thread;
- zbarimg with QR only.

The helper is Python, so it builds the same argv. A test holds the two equal, as `tests/shell/capture.sh` already holds the
slurp colours equal to the tokens. Recognised text goes to the clipboard. QR data goes through `wl-copy --sensitive`, so
clipboard history never records it (ADR-0034 PV-1) and it never appears in the result file, a notice or the journal.

### D-8. The compositor plugin, for three optional features only
The plugin is needed only for:
- click ripples (pointer-button events, then IPC to the shell);
- keystroke display (key events; gated by Q-3);
- auto-scroll (synthetic axis events at a point).

Each one is nested first, behind gates C1 to C3, and advertised as a capability. Without the plugin, or without the
capability, the option is not shown (OC-0 rule 3). Nothing in D-1 to D-7 needs the plugin.

### D-9. Privacy and security
- **Nothing leaves the machine.** No upload, link, cloud or telemetry. Any feature that sends a capture elsewhere is an
  owner decision (Q-4).
- **Lock.** Every new pixel source (freeze, text, scroll, toplevel) passes the helper's `session_locked` check before each
  grab. The thumbnails, the scroll plate and the freeze surface close when the session locks. Pins and editor windows are
  toplevels under the lock surface.
- **Private files.** Frozen frames, scroll frames, the result file and the history are 0600 files in 0700 folders, never
  links (`O_NOFOLLOW`, as the helper's existing files are).
- **History holds pre-redaction originals.** It is kept private, pruned by retention and removed by Clear History, whose
  explanation says so. Secure pixelate is irreversible in every exported file.
- **Keystroke display (R8)** can show passwords. It is opt-in per recording, never shown while the lock, a polkit or secret
  sheet, or a key sink holds the keyboard, and suppressed for `no_screen_share` windows. It needs an opus reviewer PASS and
  the owner's answer to Q-3 before it is built.
- **Recordings and hidden windows.** The OC-1 MINOR-4 limitation is unchanged: KMS recording shows password managers and
  sheets. The new overlays (clicks, keystrokes, camera) do not widen it, because the camera and clicks are the user's own.

### D-10. Dependencies: none new

| Need | Tool | Status |
|---|---|---|
| Pictures | grim, slurp, wl-clipboard | grassfield-desktop `depends` already |
| Recording, system audio | gpu-screen-recorder | Omarchy base; looked up at use time (OC-0.3) |
| GIF, trim, first frame | ffmpeg | grassfield-desktop `depends` already |
| Text, QR | tesseract, tesseract-data-eng, zbar | Omarchy base; looked up at use time |
| Editor, pins, camera, playback | Qt 6.12 Quick, Multimedia, image formats | grassfield-desktop `depends` already |
| Stitching, cropping | Python stdlib (zlib) | the helper's existing language |

Packaging lines only, no new code:
- add `optdepends` entries naming gpu-screen-recorder, tesseract and zbar (they are Omarchy base, so this is documentation);
- add `tesseract-data-fra` as an optdepend, so the owner's French is recognised (Q-5).

Not used, each for a reason:
- hyprpicker: freeze is done in D-1;
- opencv: a new dependency;
- satty and swappy: new GTK dependencies;
- omasnap: see Alternatives.

### D-11. Settings and options
- **Toolbar Options** (the macOS 27 wording), added to `CaptureModel.menuModel`: Show Floating Thumbnail, Remember Last
  Selection (the existing frame memory becomes switchable), Freeze Screen, Hide Desktop Icons; for recordings, Record System
  Audio, Do Not Disturb, and the microphone list.
- **New toolbar modes:** Capture Text and Capture Scrolling Area.
- **New key:** Shift-Super-2 for Capture Text (free in `config/hypr/grassfield/`).
- **Schema additions** under `capture.*`, each with a default and a description: `showThumbnail` (true),
  `thumbnailSeconds` (5), `thumbnailSide` (right), `freeze` (false), `hideDesktopIcons` (false), `systemAudio` (false),
  `recordDnd` (false), `historyRetention` (week), `format` (png), `standardResolution` (false), `fps` (60).
- The Screenshot app's settings window edits the advanced keys.

## Alternatives considered
1. **Adopt omasnap as the backend.** It is an Omarchy base package, MIT and Qt 6, and it already has scrolling capture, an
   editor, pins, OCR and recents [spec S5]. Rejected as the backend:
   - It captures and saves on its own, and does not know Grassfield's lock marker, so it would break SC15a.
   - It hard-codes `~/Pictures/Screenshots` and its own names, which differ from URR-036's translated folder and macOS names.
   - Its look follows Omarchy's theme and fonts, not Grassfield's glass and tokens.
   - It announces through `omarchy-notification-send`.
   - An Omarchy update could change it under Grassfield.

   Kept as a **reference implementation** (MIT; its design is data): capture first, then select; secure mosaic redaction;
   stitching; framed backdrops.
2. **Extend Preview.** Rejected: Preview's purpose is viewing (spec non-goals), and pins, the camera and history are not a
   viewer's job. Preview and the editor share the recognition code instead (D-3).
3. **The editor inside the shell (QML only).** Rejected: shell stability and memory, keyboard focus and the global menu.
   macOS opens a window for annotation.
4. **satty or swappy.** Rejected: not installed (new dependencies), GTK, and no Grassfield glass or translations.
5. **Recording through the portal (PipeWire) now.** Deferred to Q-2: it would honour `no_screen_share` and allow window
   recording, but it needs a picker answer from the helper.

## Failure modes
- **No shell running** while thumbnails are on: the capture is saved and copied, and nothing is shown. The shell's unit
  restarts. The setting can bring the notice back.
- **Recorder, tesseract or zbar missing:** the modes are not shown and the helper exits 3 (OC-0 rule 3, SC17).
- **Toplevel identifier cannot be mapped:** Capture Selected Window keeps today's on-screen box. The shadow is still added.
- **Stitching finds no overlap,** or the user scrolls back: the frames taken so far are stitched up to the last good one, and
  the plate says the area could not be joined.
- **Plugin absent:** clicks, keystrokes and auto-scroll are hidden.
- **History store unreadable:** history starts empty and is logged. Captures are not affected.

## Tests (per slice, listed in docs/specs/capture-suite.md §4)
- **L0 helper:** fakes for grim, tesseract, zbarimg and ffmpeg in `tests/shell/capture.d/`. Argv equality with Preview's
  recognition vectors, the result file's fields and mode, frames removed, lock refusals.
- **Unit:** `tst_capturethumbs.qml` (stack, timers, put-away, lock). Screenshot app C++ tests: model operations, export
  golden pictures, secure pixelate irreversibility, atomic save, history pruning, `layers.json` schema.
- **L1 nested at scale 1.25, with a fake helper:** thumbnails, freeze and loupe, scroll plate, pins. Each with a screenshot
  path, or "visual NOT verified".
- **L2 (owner):** each mode once in the real session.

## Open questions (owner)
- **Q-1** A new app in the launcher, "Screenshot" (macOS 27 has one in Utilities). Yes or no?
- **Q-2** Recording through the portal (honours hidden windows and allows window recording) instead of KMS. This needs a
  security design for pre-answering the picker.
- **Q-3** Keystroke display while recording (privacy risk). Build it as opt-in, or leave it out?
- **Q-4** Any sharing beyond the machine (links, cloud). Not in 1.0. Local LocalSend sharing as a later option?
- **Q-5** Add `tesseract-data-fra` as an optdepend, and recommend it in the French release notes?
- **Q-6** (Decided by delegation, recorded for the owner.) Save at once and offer Move to Trash, rather than macOS's save on
  dismiss.

## Consequences
- The capture gains the CleanShot-class features in about 20 slices of a day or less (spec §4), with no new dependency.
- The only new code locations are `apps/screenshot/` (one new app) and `apps/recognition.*` (moved code).
- The helper grows by about 4 subcommands and stays the single pixel owner, so the lock audit surface stays one file.
- Upload, portal recording and keystrokes wait for the owner.
