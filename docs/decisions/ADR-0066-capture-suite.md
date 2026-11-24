# ADR-0066: The capture suite (floating thumbnail, annotation, text, scrolling capture, richer recording)
Status: Proposed · Date: 2026-11-22 · Decider: owner (scope; Q-3 answered 2026-11-22); the integrator answered Q-1, Q-2 and Q-4 to Q-6 by delegation (below);
integrator (design, merge after review) · Number: 0066 (the next free number on every ref on 2026-11-22)

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
Questions that involve legal, public, security, spending or irreversible matters go to the owner.

## Decision

### D-1. One process decides and starts every capture: `grassfield-capture`
The helper (`packaging/bin/grassfield-capture`) stays the only process that decides to capture or record. Every lock check
(`session_locked`, the 0.5 s poll), the private state and the stop protocol therefore stay in one tested place.

It runs pixel tools as children, the same way it runs grim and gpu-screen-recorder today. The one new child is the
Screenshot app's `--grab-window` mode (D-3; built in slice B22, wired into the helper in slice C9). No other process starts a capture.

#### The `shooting` phase and the thumbnail handshake (slice C1)
Today `shot()` (grassfield-capture:855) writes no state when there is no timer: `write_state` runs only at :735, :894 and
from :1013. A visible thumbnail would therefore be in an immediate Shift-Super-3 picture.

From slice C1, before **every** grim call, every frozen grab and every recorder start, the helper does three things:
1. It writes `{"phase": "shooting", "seq": <random 64-bit hex>, pid, start}` to `capture-state.json`.
2. It waits for the shell's acknowledgement. The shell hides every thumbnail and writes
   `$XDG_RUNTIME_DIR/grassfield/capture-ack` holding that `seq`. The thumbnail layer has `no_anim`, so the shell writes the
   acknowledgement once its cards are unmapped and one frame has passed.

   A FileView cannot set modes, and its atomic write keeps only the mode of an existing target. The shell therefore
   pre-creates the file once with `install -m 600` in the 0700 folder (`umask 077`) before its first write, as
   `shell/notifications/Notifications.qml:1258-:1261` does for the notification history.
3. It reads the acknowledgement for at most `ACK_SECONDS` (1 s). Without one (no shell, a crashed shell, no cards shown),
   it goes on: a thumbnail can never block a capture.

Before accepting the acknowledgement, the helper checks it: a regular file, the user's own, mode 0600, not a link, at most
64 bytes, and `seq` equal to its own. The existing notice closing (`close_previous`) stays for the notice path.

**The acknowledgement contract (built in C1, written to by slice A1).** Both sides rely on exactly this:
- **The state.** While the phase is `shooting`, `$XDG_RUNTIME_DIR/grassfield/capture-state.json` (0600, by rename) holds
  `{"v": 1, "phase": "shooting", "kind": "shot" | "recording", "seq": "<16 lowercase hex digits>", "pid", "start"}`. `seq` is
  new for every shooting phase (8 random bytes). The phase lasts from the handshake to the last grim call of that capture
  (or, for a recording, to the recorder's start, when the phase becomes `recording`), and then returns to `idle`. It is
  written before every grim call, and before the recorder start, and by nothing else.
- **The file.** `$XDG_RUNTIME_DIR/grassfield/capture-ack`, in the 0700 folder. The shell writes into it, in place, once
  every thumbnail is unmapped and one frame has passed. It holds the `seq` of the state it answers: the 16 digits as ASCII,
  then at most one `\n`, and nothing else. A file of another content (an older `seq`, empty) is ignored.
- **What the helper accepts.** It opens the path with `O_NOFOLLOW` and accepts it only if it is a regular file with one
  name (`st_nlink == 1`, so neither a symbolic link nor a second name for another file), owned by the user, with permission
  bits exactly 0600, at most 64 bytes (`ACK_MAX`), and the content above for the current `seq`. It polls every 20 ms. It
  ignores anything else and keeps polling until the deadline.
- **The deadline.** `ACK_SECONDS` = 1 s from the moment the state is written. At the deadline the helper goes on without an
  acknowledgement and never fails because of it.
- **The shell's duties.** Pre-create the file once with `install -m 600` (a FileView cannot set modes; it keeps the mode of
  an existing target), write the `seq` of every `shooting` state it sees, even after it has already hidden its cards, and
  never replace the file with a link. A `shooting` state seen under the lock is stopped like any other
  (`grassfield-capture stop` ends it: the helper holds the capture lock during the phase, and a stop makes it take no
  picture).
- **No handshake without a runtime folder, or while another capture owns the state.** A screenshot taken while a
  recording or a countdown holds the capture lock writes nothing and waits for nothing (the state is theirs).

On the shell side, `CaptureFile.parse` and `stopNeeded` learn the phases `shooting` and `frozen`. A `shooting` phase under
the lock is stopped like any other (SC15a).

L0 test (C1): grim is called only after the fake shell's acknowledgement (the fakes' log timestamps); with no acknowledgement,
grim runs after 1 s; an acknowledgement with a wrong `seq`, a link or mode 0644 is ignored; the phase goes back to `idle`
after the picture.

#### Freeze: a second call, not stdin (slices C4 and A5)
The shell starts the helper with `Quickshell.execDetached` inside a uwsm scope (`shell/services/CaptureState.qml:42`), so
the helper has no stdin to read. The choice therefore comes back as a second, short helper call:
1. **The grab.** `grassfield-capture selection --freeze` runs the C1 handshake, then grabs every output with grim into
   `$XDG_RUNTIME_DIR/grassfield/frozen/` (0700 folder, 0600 files). It writes
   `{"phase": "frozen", "token": <random 128-bit hex>, "frames": [{"output", "path", "rect", "scale"}], pid, start}`.
2. **The wait.** It waits at most 120 s for a choice, cancelled earlier by `stop` (Ctrl-Super-Esc) or the lock.
3. **The choice.** The shell shows the frames and, on the user's choice, runs
   `grassfield-capture choose --token T --geometry "X,Y WxH"` (or `choose --token T --cancel`).
4. **Validation by `choose`:**
   - the token is exactly 32 lowercase hex digits and equals the state's token;
   - the state's `pid` and `start` name a live helper of this user (`own()`, the stop rules);
   - the geometry matches `GEOMETRY_ARG`, has a positive size and lies wholly inside one frozen frame's `rect`.
   If all hold, `choose` writes `capture-choice.json` (O_EXCL, 0600, by rename) and exits 0. Otherwise it exits 2 and writes
   nothing.
5. **The crop.** The waiting helper polls for `capture-choice.json` every 50 ms. Before trusting it, it checks it the same way
   (regular file, owner, 0600, no link, at most 4 KiB, JSON v1, token equal, geometry inside a frame). It then deletes the
   choice, crops the frozen frame (logical to device pixels with the frame's scale, rounded outwards) and goes on as a
   normal shot.
6. **Cleanup.** Every frozen file and the choice file are removed on finish, cancel, timeout, SIGTERM and lock. A
   left-over `frozen/` folder is removed at the next helper start.

As built in slice C4 (`packaging/bin/grassfield-capture`, tests `tests/shell/capture.d/freeze.py`):
- The frames are binary PPM files (`frozen/0.ppm`, `1.ppm`, ... one per enabled display, the focused one first; `grim -t ppm`), so
  that a crop is a slice of rows and the helper needs no PNG decoder; the crop is written as an 8-bit RGB PNG with the
  `Grassfield-Scale` chunk. A frame is read only as a private file (regular, no link, one name, 0600, at most 256 MiB).
- The state's `kind` stays `shot`; the phase `frozen` is also ended by `stop` (SIGINT to the helper, which holds the capture lock).
- The choice file is `{"v": 1, "token": T, "geometry": "X,Y WxH"}` or `{"v": 1, "token": T, "cancel": true}`, nothing else; the
  state is read by `choose` as a private file of at most 4 KiB. Tokens are compared with `hmac.compare_digest`.
- Exit codes of `choose`: 0 written; 2 for a usage error, a wrong token, a state that is not a frozen screen of a live helper of
  this user's (pid and start time), or a geometry not wholly inside one frame; 1 under the lock or when the file cannot be
  written. `selection --freeze` refuses `--timer`, `--geometry` and `--previous` (usage, exit 2) and exits 1 under the lock.
- The helper ignores (leaves in place) an invalid choice file; `choose` replaces it by rename, a link included, never following it.
- The device rectangle is the logical one times the frame's scale, rounded outwards (floor, ceil) and clamped to the frame.

#### Other new subcommands
- `text [--geometry G]`: recognise text and QR codes in an area (D-7, slice C3).
- `scroll --geometry G`: a scrolling capture (slices C5 and C6). It takes region frames (`grim -t ppm -g`, at most 8 per
  second, each after the C1 handshake on its first frame only) until `stop` or the plate's Done, which goes through
  `choose --token T --done`, using the freeze channel's rules. It stitches in Python stdlib: row hashes, overlap search, a
  fixed header and footer kept once, at most 20 000 px. The PNG is written through zlib.
- `window --address A`: the window alone. The helper reads the address from `hyprctl clients`; for the toolbar's choice,
  slice A14 passes the address Grassfield's window list already holds instead of `--geometry`.

  The helper checks the lock itself before the grab, then runs `grassfield-screenshot --grab-window A --out <hidden file>`
  (D-3, slices B22 and C9). `--grab-window` also refuses to run while the session is locked: it reads the same lock marker
  through the shared reader rules, so it never relies on the caller alone.

  **Fail closed on hidden windows.** If the B22 spike shows that a `no_screen_share` window is exported with its pixels,
  `window --address` refuses every window that has `no_screen_share` (Hyprland's effective property, read with
  `hyprctl -j getprop`, as the share picker does: docs/specs/system-dialogs.md SP6). For such a window it falls back to
  today's on-screen box through grim, where Hyprland blacks the window out. If the property cannot be read, it also falls
  back to grim.
- `record ... [--system-audio] [--mic NAME] [--fps 30|60] [--quality Q]` (D-6, slice C7).

#### The result channel (slice C2)
After each capture the helper writes `$XDG_RUNTIME_DIR/grassfield/capture-result.json` (0600, by rename):

    {"v": 1, "id", "kind": "shot" | "recording" | "text" | "scroll", "paths": [...], "primary",
     "output", "rect", "scale", "pixels" {w, h}, "time", "text"}

- `text` holds the first 512 characters of the recognised text, never QR data. It is `""` for a picture and a recording.
- The file is written once the shooting phase is over (the state `idle`), by a file of its own (`O_EXCL`, 0600, never a
  link) renamed over the last result, so the shell reads a whole file or the one before.
- `paths` are the saved files (one per display for `screen`), `primary` is the first (the one copied). `rect` is the
  logical rectangle of `primary`'s capture, `output` the display it is on, `scale` that display's scale, `pixels` the
  picture's size in device pixels (read from the PNG header; a recording's is its rectangle at the scale), `time` is
  milliseconds since the epoch, `id` 16 random hex digits.
- When `capture.showThumbnail` is true (the default; any value that is not a boolean reads as the default) and the file can be
  written, the result is written, whether or not a shell answered.
- **The notice is skipped only when all three hold for this very capture:** the shell acknowledged its `shooting` phase
  (`handshake` returned true), `capture.showThumbnail` is true, and the result file was written. In every other case the
  notice is sent as it is today: no acknowledgement within 1 s (no shell, a shell without thumbnails), no runtime folder, the
  result could not be written, `showThumbnail` false, or a shot taken while a recording or countdown owns the state (no
  handshake). So a capture is never left without feedback while the shell has no thumbnail surface.
- When `showThumbnail` is false **no result file is written**, so a shell on a stale setting never shows both.
- No result is written for a capture that is not offered a notice today: Save to Clipboard (no file) and Preview (opened at
  once).
- The automatic copy of a saved picture is `wl-copy --type image/png --sensitive`. Save to Clipboard is the user's own copy
  and stays a normal one.

### D-2. The shell owns what is on screen during and right after a capture
New shell surfaces, all in `shell/capture/` (an existing directory), each a layer with its own namespace and `no_anim`:
- `CaptureThumbnails.qml`, namespace `grassfield-capture-thumbnail`: the floating thumbnail. It takes no keyboard and is
  hidden while locked and during `shooting` (D-1).
  - A drag out offers `text/uri-list` (the DesktopIcon precedent).
  - Before any action on a result path (Copy, Show in Files, Move to Trash), the shell checks that the path is a regular file
    and not a link. It also checks that the path lies directly inside one of the folders Save to can write to, resolved the
    way `shell/store/CaptureLocation.js` and the helper's `destination()` resolve them (the Screenshots folder, Videos,
    Desktop, Documents). The folder the result file names is never trusted, so a forged result cannot point at another
    file. Move to Trash then runs `gio trash` through the shell's helper environment.
  - The picture is loaded with `Image { source: <file URL>; sourceSize: <card size in device pixels> }`. Qt's file loader
    decodes at the requested size. Notifications instead draw into a Canvas, because B-19 found that Quickshell's image
    provider ignores the requested size, so the image provider is not used here. Peak memory is checked in slice A2.
- A freeze and loupe mode in `CaptureToolbar.qml`: the frozen frames at device pixels, a ×8 loupe and a readout, and the
  `choose` call (D-1).
- `CaptureScrollPlate.qml`: the scrolling capture's frame, Done, Cancel and a live strip preview.
- `CaptureClicks.qml` (slice A11, only when the plugin offers the capability): click ripples while recording.

### D-3. The editor, pins, history and camera: a new Qt Quick app, "Screenshot"
`apps/screenshot/` (a new directory, needed for a new binary) builds `grassfield-screenshot`, app id
`org.grassfield.Screenshot`, in the `grassfield-desktop` package. That is a new binary and a `.desktop` file, not a new
package. It is C++ with Qt Quick, built with CMake like `apps/preview`, and follows the shared `Grassfield.Ui`, the unified
toolbar (ADR-0015) and the global menu (ADR-0008).

| Mode | Command | What it is |
|---|---|---|
| Editor (default) | `grassfield-screenshot <file>` | The annotation window. |
| Pin | `--pin <file>` | A floating picture (app id `org.grassfield.Screenshot.Pin`, window rule in `config/hypr/grassfield/windows.lua`). |
| Recent Captures | `--history` | The history window (D-5). |
| Camera | `--camera` | The camera overlay for recordings. |
| Compose | `--compose window <in> <out>` | Headless: shadow and transparent corners for a window capture. |
| GIF, first frame | `--gif <in> <out>`, `--first-frame <in> <out>` | Headless ffmpeg runs (D-6). |
| Grab window | `--grab-window <address> --out <file>` | Headless, run **only by the helper**: a small Wayland client of `hyprland-toplevel-export-v1` that captures the window with that Hyprland address and writes a PNG. It refuses under the lock. |

**Why `--grab-window` uses `hyprland-toplevel-export-v1`.** Nothing installed lists ext-foreign-toplevel identifiers: grim
cannot, no Quickshell type exposes them, and the helper is stdlib Python. The export protocol has two requests, and spike B22
evaluates both:
- `capture_toplevel` takes a **32-bit** handle (`hyprland-toplevel-export-v1.hpp:127`: `uint32_t`), not the full 64-bit
  address `hyprctl clients` prints. The headers do not show how Hyprland maps that handle to a window. The spike finds out
  (expected: the low 32 bits of the address). The client refuses when two live windows share those bits.
- `capture_toplevel_with_wlr_toplevel_handle` (:129) takes a `zwlr_foreign_toplevel_handle_v1`. The client lists the wlr
  foreign toplevels and matches the window by app id, title and state (the wlr handle carries no geometry) against `hyprctl clients`. It is preferred when
  the match is unique.

The spike also checks whether Hyprland 0.56 returns black for, or refuses, a `no_screen_share` window (the fail-closed rule in
D-1 applies otherwise), and whether rounding and alpha come through. The protocol XML is not installed on this machine: `/usr/include/hyprland/protocols/` has only the generated
server header, and no package owns `/usr/share/hyprland-protocols`. The build therefore needs one of two things, chosen in
B22:
- a new **build-only** makedepend, `hyprland-protocols`;
- or the one XML file vendored with its licence (checked by `just check-licenses`).

Run-time dependencies do not change either way.

The document model is C++: a list of vector layers over the original picture. QML draws the layers for interaction.
Export renders the same model with QPainter at the picture's device pixels, which makes export deterministic and
golden-testable.

Code shared with Preview: `preview::recognitionCommand` and the TSV parsing move into one source compiled into both
binaries, `apps/recognition.{h,cpp}`, beside the shared headers already in `apps/` (`appscope.h`, `textrender.h`).

Why a new app:
- Preview's spec makes viewing its purpose and lists annotation as a non-goal (docs/specs/preview.md:18-:22).
- The shell must not hold editors, camera streams or minutes-long documents (shell stability, the unit's memory limit).
- macOS edits in a window with normal focus and a global menu.

### D-4. File formats
- **Pictures:** PNG by default, as today. The app's settings can choose JPEG or WebP (Qt's image plugins, already a
  dependency). "Save at Standard Resolution" writes the logical size on a scaled display.
- **Recordings:** MP4 (H.264, as today). GIF is an export made by ffmpeg (palettegen and paletteuse, 15 fps, at most 1280 px
  wide).
- **No new user-facing file type.** An editable document is a history entry: the original and `layers.json`
  (`{"v": 1, "layers": [...]}`, validated by unit tests). No new MIME registration.

### D-5. Storage (URR-036 kept)
- **Where files go is unchanged:** Save to (by default Pictures > Screenshots, named in the session's language), recordings in
  Videos, macOS names, hidden file then link, keys following `capture.location`.
- **A capture is saved at once,** as today (Q-6). macOS keeps it unsaved until the thumbnail goes; Grassfield keeps the keys
  and older paths unchanged, and a crash or logout never loses a capture. Move to Trash on the thumbnail undoes a save.
- **Annotate.** Done replaces the file atomically (hidden file, then rename) and keeps the original in the history for
  Revert. "Save as Copy" writes `<name> (edited).png` beside it.
- **History:** `$XDG_STATE_HOME/grassfield/capture-history/` (0700, files 0600):
  - `index.json` (`{"v": 1, "entries": [...]}`; each entry `id`, `kind`, `path`, `time`, `w`, `h`, `orig`, `cur`; **no recognised text**), plus per entry `original.png` and `layers.json`.
    As built in slice B2: `orig` and `cur` are the SHA-256 of the picture file as captured and as Done last wrote it (`cur` is
    empty before the first Done and after a Revert). An entry names a file only while the file's bytes are one of the two, so
    a later capture that reuses the path never gets another picture's original back, and Revert is offered only for a file the
    editor itself wrote. One entry exists per path; a new one for the same path replaces the older and removes its folder;
  - retention 1 day, 1 week (default) or 1 month, pruned at each capture and at app start; Clear History removes everything;
  - an entry whose file is gone is dropped; clipboard-only captures are never kept.
- **Temporary frames** (freeze, scroll), the result, the acknowledgement and the choice: `$XDG_RUNTIME_DIR/grassfield/`
  (tmpfs, 0700), removed as described in D-1.

### D-6. The recording pipeline
- **Kept for 1.0 (Q-2):** gpu-screen-recorder with the KMS backend and Omarchy's arguments (OC-1), plus the stop, lock and
  pidfd protocol.
- **Added options:** system audio (`-a default_output`, merged with the microphone by `|` as Omarchy does; off by default),
  a choice of microphone (PipeWire sources by name), 30 or 60 fps, and quality (`-q`).
- **After recording:** first frame and GIF through `grassfield-screenshot --first-frame` and `--gif` (ffmpeg, already a
  dependency). Trim in the app (Qt Multimedia playback, ffmpeg `-ss/-to`, stream copy or re-encode). Do Not Disturb while
  recording, as an option.
- **Later, with a security design:** the portal backend (`-w portal`) would honour `no_screen_share` and allow window
  recording, but it needs a picker answer from the helper.

### D-7. Text recognition: tesseract and zbar, Preview's contract with a different page mode
Notes and Preview already run the tesseract CLI (Omarchy base packages). The suite uses the same contract as Preview (OC-2),
with one difference: the page segmentation mode.
- languages: `tesseract --list-langs` ∩ {the session's language, eng};
- `--oem 1 --dpi 300`;
- page mode: `--psm 6` (one block of text, Omarchy's choice for a region). Preview keeps `--psm 3` for a whole picture
  (previewlogic.cpp:231);
- plain text output for the clipboard (Preview reads TSV word boxes);
- lowest CPU priority, one OpenMP thread;
- zbarimg with QR only.

The helper's argv equals Preview's in every field except `--psm` and the output format; the slice C3 test holds that.
Recognised text goes to the clipboard. QR data goes through `wl-copy --sensitive`, so clipboard history never records it
(ADR-0034 PV-1), and it never appears in the result file, a notice or the journal.

### D-8. The compositor plugin, for three optional features only
The plugin already observes pointer buttons and keys for other features (`compositor/src/main.cpp:138`, `:191`;
`OverviewFocus.cpp:499`; `ToplevelDrag.cpp:929`). The suite adds observers of the same events, never cancelling them, for:
- click ripples (slices D1 and A11);
- keystroke display (slice D2: the owner said yes, protected, on 2026-11-22; built last, opus review);
- auto-scroll, through synthetic axis events (slice D3).

Each is advertised as a capability, nested first, behind gates C1 to C3. Without the plugin or the capability, the option is
not shown (OC-0 rule 3). Nothing in D-1 to D-7 needs the plugin.

### D-9. Privacy and security
**Nothing leaves the machine in 1.0 (Q-4).** No upload, link, cloud or telemetry.

**Lock.** Every new pixel source (freeze, text, scroll, `--grab-window`) passes `session_locked` before each grab. The
thumbnails, the scroll plate and the freeze surface close when the session locks. Pins and editor windows are toplevels
under the lock surface.

**Private files.** Frozen frames, scroll frames, the result, the acknowledgement, the choice and the history are 0600 files
in 0700 folders, opened with `O_NOFOLLOW` and checked for owner, mode, type and size before use.

**Unredacted copies.** Three copies of a capture exist before the user redacts it.
1. *The clipboard.* Today every saved shot is copied to the clipboard (grassfield-capture:922-:924), and clipboard history
   records it. From slice C2:
   - the automatic copy goes through `wl-copy --type image/png --sensitive`, so clipboard history (ADR-0034 PV-1) never
     records it;
   - a Copy the user asks for (the thumbnail, the editor) is a normal copy;
   - after an export that contains a Redact, Pixelate or Blur layer, the editor puts the exported picture on the clipboard,
     replacing the automatic copy.

   Delegated decision: macOS's own behaviour is not documented. The privacy-first default costs only that an untouched
   capture is not in clipboard history until the user copies it.
2. *The saved file* stays unredacted until Done replaces it.
3. *The history original* is kept on purpose for Revert. It is private, pruned by retention and removed by Clear History,
   whose explanation says it holds the pictures as they were taken. Until slice B14 builds Clear History the original stays in the history and the
   layers stay editable: Redact hides the area in the saved picture, not in the history entry, and the tools' texts say "in the saved picture".
   After an export that hides pixels the editor ALWAYS replaces the clipboard (owner decision, "toujours remplacer"), with no check of what it holds, using `wl-copy --type image/png --sensitive` and the saved file's bytes; the call blocks for two seconds at most (no event loop, so a close request cannot cut it short), and on failure or timeout `wl-copy --clear` runs and Done reports the error.

**Redaction tools and what they guarantee.**
- **Redact** (solid fill, default black, opaque): the area's pixels are replaced in every exported file. This is the tool for
  secrets.
- **Pixelate**:
  - each block is replaced by its mean colour plus per-block noise;
  - the blocks are at least 12 device pixels, on a grid with a random offset;
  - no source pixel survives inside the area.

  Large shapes and colours stay recognisable, and short known strings can be guessed by comparing pixelated candidates. The
  tool's tooltip points to Redact for secrets.
- **Blur** is offered for looks only and labelled as not hiding text.

**Keystroke display (R8)** can show passwords. **Owner decision Q-3 (2026-11-22): yes, protected** (asked with options; the
owner chose "Oui, protégée"). Slice D2 is built last with this design:
- built last, as a per-recording opt-in with a warning;
- never shown while the lock, a polkit or secret sheet, or a key sink holds the keyboard;
- suppressed for `no_screen_share` windows;
- an opus reviewer PASS.

**Recordings and hidden windows.** The OC-1 MINOR-4 limitation is unchanged for 1.0: KMS recording shows password managers
and sheets.

**For the opus security reviews** (slices C2, C4, C9, B22, A3, B7, B14 and D2):
- the result-file path checks before `gio trash`, Copy and Show in Files (a regular file, not a link, inside one of the configured Save-to folders, never the folder a result names);
- recognised text is sensitive: the result file's `text` field is runtime-only (0600) and the history index holds none;
- the freeze and scroll channel's validation (D-1);
- `--grab-window` and hidden windows.

### D-10. Dependencies: none new at run time

| Need | Tool | Status |
|---|---|---|
| Pictures | grim, slurp, wl-clipboard | grassfield-desktop `depends` already |
| Recording, system audio | gpu-screen-recorder | Omarchy base; looked up at use time (OC-0.3) |
| GIF, trim, first frame | ffmpeg | grassfield-desktop `depends` already |
| Text, QR | tesseract, tesseract-data-eng, zbar | Omarchy base; looked up at use time |
| Editor, pins, camera, playback | Qt 6.12 Quick, Multimedia, image formats | grassfield-desktop `depends` already |
| Window grab | wayland client library (a dependency of qt6-wayland); the protocol XML | build only: wayland-scanner, plus `hyprland-protocols` as a new makedepend or the XML vendored (D-3) |
| Stitching, cropping | Python stdlib (zlib) | the helper's existing language |

Packaging lines (Q-5):
- `tesseract-data-fra` as an optdepend, so French text is recognised;
- optdepends entries naming gpu-screen-recorder, tesseract and zbar (documentation only).

Not used: hyprpicker (freeze is done in D-1), opencv (a new dependency), satty and swappy (new GTK dependencies), omasnap (see
Alternatives).

### D-11. Settings and options
- **Toolbar Options** (macOS 27 wording): Show Floating Thumbnail, Remember Last Selection, Freeze Screen, Hide Desktop
  Icons; for recordings, Record System Audio, Do Not Disturb and the microphone list.
  Do Not Disturb while recording is a runtime silence only (owner decision, 2026-11-24, "temporary silence"): the notification
  service shows no banner while a recording runs and `capture.recordDnd` is on, as macOS does while sharing the screen. The saved
  `notifications.dnd` is never read back or written by the capture, nothing is persisted, and the Do Not Disturb indicators follow the
  user's own setting only.
- **New toolbar modes:** Capture Text and Capture Scrolling Area.
- **New key:** Shift-Super-2 for Capture Text.
- **Schema additions** under `capture.*`: `showThumbnail` (true), `thumbnailSeconds` (5), `thumbnailSide` (right),
  `freeze` (false), `hideDesktopIcons` (false), `rememberSelection` (true), a timer value `"3"`, `systemAudio` (false), `recordDnd` (false), `historyRetention` (week),
  `format` (png), `standardResolution` (false), `fps` (60).
- `config/schema/grassfield.schema.json` is edited by lanes A, B and C. It is listed as a shared file in the spec's lane
  table, and one slice at a time changes it.

## Owner decision
- **Q-3** Keystroke display while recording (a security decision: it can show passwords typed in any app). Asked on
  2026-11-22 with three options (yes protected / not for 1.0 / never); the owner chose **yes, protected**: off by default,
  opt-in per recording, suppressed under the lock, polkit and secret sheets, key sinks and `no_screen_share` windows,
  opus reviewer PASS before it ships. Slice D2 is no longer blocked; it stays last.

## Delegated answers (integrator, 2026-11-22, under the owner's delegation)
- **Q-1** A "Screenshot" app in the launcher: **yes** (macOS 27 has one in Utilities).
- **Q-2** Recording backend: **KMS for 1.0**. The portal comes later, with a security design for the picker.
- **Q-4** Nothing leaves the machine in 1.0. The owner decides any sharing later.
- **Q-5** `tesseract-data-fra` is added **as an optdepend**.
- **Q-6** A capture is **saved at once**; the thumbnail offers Move to Trash.

## Alternatives considered
1. **Adopt omasnap as the backend.** It is an Omarchy base package, MIT and Qt 6, and it already has scrolling capture, an
   editor, pins, OCR and recents. Rejected as the backend:
   - It captures and saves on its own and does not know Grassfield's lock marker, so it would break SC15a.
   - Its save folder is configurable (its README's `[output] directory`), but its default and its name template differ from
     URR-036's translated folder and macOS names, and Grassfield would have to write omasnap's config file.
   - It follows Omarchy's theme and fonts, not Grassfield's glass and tokens.
   - It announces through `omarchy-notification-send`.
   - An Omarchy update could change it under Grassfield.

   Kept as a **reference implementation** (MIT; its design is data): capture first, then select; mosaic redaction;
   stitching; framed backdrops.
2. **Extend Preview.** Rejected: Preview's purpose is viewing. Preview and the editor share the recognition code instead.
3. **The editor inside the shell.** Rejected: shell stability and memory, keyboard focus and the global menu.
4. **satty or swappy.** Rejected: new GTK dependencies, no Grassfield glass or translations.
5. **Recording through the portal now.** Deferred (Q-2).
6. **A window grab through ext-foreign-toplevel identifiers (grim `-T`).** Rejected: no installed tool maps a Hyprland window
   to its identifier.

## Failure modes
- **No shell running** while thumbnails are on: the acknowledgement times out after 1 s; the capture is saved and copied, and
  nothing is shown. The setting brings the notice back.
- **Recorder, tesseract or zbar missing:** the modes are not shown and the helper exits 3 (SC17).
- **`--grab-window` fails** or the window has gone: Capture Selected Window keeps today's on-screen box.
- **`choose` sends a bad token or geometry:** exit 2, nothing written. The waiting helper times out at 120 s and removes its
  frames.
- **Stitching finds no overlap:** the frames joined so far are kept and the plate says so.
- **Plugin absent:** clicks, keystrokes and auto-scroll are hidden.
- **History store unreadable:** history starts empty and is logged.

## Tests
Per slice, in docs/specs/capture-suite.md §4: L0 helper fakes, QML unit tests, C++ gtest with golden exports, nested L1 at
scale 1.25 (each with a screenshot path or "visual NOT verified"), and L2 for the owner.

## Consequences
- The capture gains the CleanShot-class features in about 50 slices of a day or less (spec §4), with no new run-time
  dependency.
- The new code locations are `apps/screenshot/` and `apps/recognition.*` (moved code).
- The helper stays the single place that decides captures, so the lock audit surface stays one file plus one small grab mode.
