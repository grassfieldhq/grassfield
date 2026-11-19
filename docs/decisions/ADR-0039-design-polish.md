# ADR-0039: Design polish: one grammar for materials, controls, windows and accessibility settings
Status: Accepted, built (steps 0 to 5 merged; steps 6 to 28 in #88, the owner's one pull request of 2026-10-31; what waits
on other pull requests is listed in their rows). Proposed in the owner brief "Cohérence et finition", 2026-10-29 (step 0: docs
only, no code). The owner answered Q1 to Q8
on 2026-10-29 (AskUserQuestion), recorded in "Owner decisions (2026-10-29)"; revised after the integrator's review of step 0
(FAIL: one MAJOR, four MINORs; "Review history"); the steps start one pull request each ·
Date: 2026-10-29 · Decider: owner (Q1 to Q8), integrator (the steps, the review, the nested pass) · Number: 0039 (free on
main 11c9e69 when step 0 began; #41 and #43, open then, have merged since)

Builds on ADR-0024 (macOS 27 structure, macOS 26 glass) and does not change its direction or its values: it closes the
seams ADR-0024's lots left between surfaces, and the places where an accessibility setting stops short. Measurements:
`docs/audits/design-polish-2026-10-29.md` (cited "audit §n"), captures in `docs/audits/design-polish-2026-10-29/shots/`.

## Context

### The owner's brief (2026-10-29)
- One pull request per step toward main. Step 0 (this one): an audit from `docs/audits/ui-finesse-2026-10-25.md`,
  `docs/audits/visual-tahoe-2026-10-25.md` and ADR-0024, on coherence (materials, typography, icons, windows, accessibility)
  and finish (motion, Files, Settings, Preview, Store, panels and menus); an ADR with the measured gaps, a prioritised list of
  small steps, and the owner's questions, each with two or three options, their pros and cons and a recommendation.
- Tokens only; real blur only (BackgroundEffect or layer rules); no Apple asset or Apple trademark name in the UI.
- Not touched until merged, and planned after: `apps/files` and `apps/portal` (pull request #41), `apps/store` (step 3c), the
  Software Update panel (step 3: `apps/settings/qml/SoftwareUpdate*.qml`, `shell/services/SoftwareUpdate.qml`,
  `ui/Grassfield/Ui/SoftwareUpdateLogic.js`), `apps/activity`, `shell/dock`, `shell/desktop`, `shell/menubar`,
  `ui/Grassfield/Ui/Appearance.qml` and `Material.qml` (fixes in progress). `shell/security` is out of this work.
- What the container cannot verify (the nested session, rendering with blur, motion) is written NOT VERIFIED; the integrator
  runs the nested pass.
- Since step 0 was written, pull requests #41 (Files and the portal), #43 (tiling step 5) and #44 (Software Update step 3)
  merged (main 35e62c5, merged into this branch): `apps/files`, `apps/portal` and the Software Update panel are free now.

### What holds on main 11c9e69 (audit §2)
- ADR-0024's lots 1 to 6, T-1 and T-3 are merged. On the renders of the real `Grassfield.Ui` and Settings: white text on the
  selection fill in both appearances, white windows (255) with light groups (247) and an edge-to-edge sidebar (236), the
  traffic lights on whole pixels, stroke-2 symbols (34.5–40.4 % solid pixels against 13–26 % before).
- Tokens: no literal radius, font size, opacity, geometry value or animation duration in the QML of `ui/`, `shell/` and
  `apps/`; 20 literal colours, none of them a UI colour (audit §5).

### Measured gaps (audit §3 and §4)

| ID | Gap | Measure | Evidence |
|---|---|---|---|
| G1 | Glass surfaces without a glass class take the pre-ADR-0024 single tint | 4 classes exist; the Overview band, widget gallery, widgets, switcher, tooltips, Stages badges and the tails of the Dock menu, stack popup and tooltip draw 0.85 at the default slider (targets: band and gallery 0.15, widgets 0.92; tails: their body's class, which adapts) (step 22, audit §3.18: `glass.gallery` 0.15 and `glass.widgets` 0.92; the badges on `controls`, every other text surface on `menu`; the tails on their body's glass as drawn; the close capsules opaque under Reduce Transparency and frosted by Increase Contrast; the inner rim stronger toward the top left; Increase Contrast raises the dark edge to 0.96; the Dock shelf with step 25; on screen NOT VERIFIED; step 25: the shelf keeps Material's darker outer edge and its bright inner rim, `dock.rimOpacity`'s light outer rim goes) | audit §3.1; `Appearance.qml:160` |
| G2 | The shell's sheets ask for a blur 2 pt squarer than they are drawn | blur radius 24 (`radius.alert`), shape 26 (`radius.sheet`) (closed by step 4: the blur takes the dialog's own corner; on screen NOT VERIFIED here) | `shell/overlay/Overlay.qml:132-144`, `Dialog.qml:25` |
| G3 | Three button grammars, two sheet grammars | default 32-pt radius-6 rectangle (every app sheet), push 24-pt capsule (Settings rows, shell sheets), capsule 28 (alerts) (step 10, after D-Q1's measurement of macOS 27's Print and Open sheets: every sheet, the shared `Sheet` and the shell's, ends with `Button.sheet`, a 24-pt rounded rectangle with a 7-pt corner, the Cancel and default pair one width, 20 from the right and bottom edges; Settings' rows keep the push capsule and alerts the 28-pt capsule, as macOS 27 draws both) | audit §3.6; `shots/gallery-light-2x-controls.png` |
| G4 | Sheets rounder than the windows they sit on | sheet 26, alert 24, window 16.0 (circle-equivalent of Hyprland's 20 at power 2.6; macOS 27: 16.6) (step 10: `radius.sheet` 16, as macOS 27's sheets measure (15.4–17.1); `radius.alert` 26, as its alerts measure (25.6–27.3), the owner's choice of 2026-10-31; audit §3.8) | audit §3.2 (C-2) |
| G5 | Non-concentric inner shapes | switcher selection 26 for 10.5, sheet controls 6 for 10, Now Playing artwork 6 for 16 and 10, Force Quit rows 6 for 2, stack rows 6 for 1–7 (step 13, measured on macOS 27 first, audit §3.11: `radius.group` 12 for Settings' groups; the switcher's panel 60 and selection 33 at padding 22, concentric; the cover art 10, as macOS 27's Control Center draws it, not concentric there; Force Quit's and the stack's rows concentric, a stack grid cell kept at 6; a notification's icon tile at an app icon's corner; rounded suggestion thumbnails; the sheet's controls with step 10) | audit §3.2 |
| G6 | One role, eight hover or selection fills | accent; `text` 0.12; `fill` 0.06, 0.14, 0.28, 0.42; `hover` 0.12; a rim token 0.22 (step 12 on the surfaces it names: the control hover, `hover` at 0.12; the neutral selection of an item on glass, `hover` at `material.selectionOpacity` 0.25, macOS 27's App Switcher measured; the accent selection; no multiplier of the panel fill or rim token left in the stack popup, the Overview, the switcher or the tiling suggestions; Search's 0.06 and Quick Settings' rows stay with their own surfaces' steps; audit §3.10) | audit §3.6 |
| G7 | About twenty hand-made focus rings | the shared `FocusRing` used once in the shell; rings inside the shape, in the accent, or shown after a click (`activeFocus`) (closed on the free surfaces by step 7: `KeyFocus` gives an item that is not a Control its keyboard-only state, as Qt 6.11 has no `focusReason` on a plain Item; Clear All is the Tab stop before the cards; the Stages tiles stay off the keyboard as on macOS 27 (the owner's decision of 2026-10-31: no keyboard path to the strip, as macOS without Full Keyboard Access; the tiles keep their accessible names and press actions); Files, the menu bar and the Store with steps 23 to 25; step 24: the Store's shelf, hero, category tiles, (…) button, account row and operation ring show the ring for the keyboard only, `KeyFocus`) | audit §3.7.3 |
| G8 | Increase Contrast cuts the inline pop-up's label | its border is drawn around a bezel-less pop-up whose text starts at 0: "Icon theme" reads "\|con theme" | `shots/increase-contrast-popup-light-zoom4.png`; `ComboBox.qml:104, :123` |
| G9 | Increase Contrast leaves switches and sliders unoutlined | off track on its backdrop 1.14:1, knob on track 1.57:1, with or without the setting (closed under Increase Contrast by steps 1 and 2: tracks, knobs, the slider outline above its fill; with the setting off the knob stays 1.25:1 against its off track on opaque material, the integrator's measure on #61: step 28; closed by step 28 with the setting off: the knob of Toggle and Switch casts macOS 27's soft drop shadow, a real `RectangularShadow` on `control.knobShadow*` (0.22, blur 3, offset 0.5), measured on its Settings capture, audit §3.24) | `shots/gallery-light-ic-2x-controls.png`; `Toggle.qml`, `Switch.qml`, `Slider.qml` |
| G10 | Reduce Motion shortens instead of replacing | of 80 timed animations, 55 are only capped at 100 ms, so slides still move: banners and the Notification Center slide in, knobs, Overview tiles, Search's height; 1 is not gated (the saver's 1500-ms crossfade) (closed on the free surfaces by step 5; the Dock, the menu bar and the Files tab bar with steps 25 and 23; step 23 closed the tab bar; step 25: an auto-hidden Dock fades in place under Reduce Motion, a lifted widget does not grow, the Dock's easings on the roles' curves (the hops keep their gravity); after #83 merged, the menu bar's band shows under Reduce Transparency and Increase Contrast and stays opaque when dimmed) | audit §3.7.4 |
| G11 | Preview is outside ADR-0024's window rules | window `materialTint` #F3F4F6 / #1D1F24 instead of #FFFFFF / #292929; no `windowSurface`; the macOS 26 floating sidebar; floating glass toolbar groups with 28-pt buttons; text selection in the accent (the window neutrals, `windowSecondary` and the selection closed by step 3; the sidebar and the toolbar closed by step 16: the edge-to-edge sidebar, the toolbar's rimmed capsules with 34-pt buttons, scroll bars, the toolbar's rule) | audit §4.4; `apps/preview/qml/Viewer.qml:51, :618-630` |
| G12 | Settings reach only part of the apps | Increase Contrast and Text size: not in Files or Preview; Settings' glass preview ignores Reduce Transparency (Preview closed by step 3; Files closed by step 23: `FilesApp` reads both settings as the Store does, and Files' text follows Text size through the typography tokens, `files.iconLabelSize` and the preview pane's name pitch; the glass preview closed by step 15: the glass controls' class tint, opaque and unblurred under Reduce Transparency) | audit §3.3, §3.7 |
| G13 | No text hierarchy in dark app windows | secondary #DCDCE4 10.67:1 against text 13.36:1 on #292929 (luminance ratio 1.27; light: 14) | `shots/settings-desktop-dark-2x-crop.png`; audit §3.7.1 |
| G14 | Two greens for "on" in the dark appearance | switches and slider fills #4FB36B (white knob 2.63:1), checkboxes, radios, default buttons #2E8049 (4.88:1) | `shots/gallery-dark-2x-controls.png` |
| G15 | Light windows have no dark contact edge (C-4) | `col.active_border` white 0.15 in both appearances; macOS 27 about black 0.25 in the light one (closed in code by step 6: the shell pushes the appearance's pair; on screen NOT VERIFIED here) | `config/hypr/grassfield/looknfeel.lua:13-14` |
| G16 | Four toolbar edges, three capsule drawings, four search fields | none / 1-px rule / gradient fade / none; `RimmedCapsule` / plain fill / floating glass; the shared `SearchField` used nowhere; no tooltip on icon-only toolbar buttons (step 14: `toolbar.*` one token group for the capsules, group buttons, divider, rims and search height, read by Settings, the Store, Activity Monitor, Files and `RimmedCapsule`; `SearchField` is the rimmed 28-pt capsule, used by Settings and Activity Monitor, and a text field draws its placeholder at last; icon-only `ToolButton`s name themselves in a tooltip; the toolbar edges and the Files, Preview and Store fields with steps 16, 23 and 24; step 23: Files' back and forward, view switcher, Group By, Action and the panels' path pop-up on `RimmedCapsule`, Tags and Action in one capsule (Finder groups Share, Tags and Action; Files has no Share) as macOS 27 Finder groups it, the search circle rimmed with the shared ring outside it and a clear button; step 24: the Store's sidebar search is the shared `SearchField`, 28 tall in its measured 29-pt slot, with the clear button) | audit §3.5, §3.6, §3.4 |
| G17 | Menus re-implemented with other metrics | section headers ignore the check column (`PopupMenu.qml:316-328`); Volume rows 4 apart; the tiling popover's neutral highlight and 13-pt headers; stack labels at 34; the Dock menu's "Recent Documents" as a greyed row (step 8 closes all but the Dock menu, step 25: one `MenuHeader` for every section title, PopupMenu's headers after the check column since 2026-10-30; the sound menu's rows with no gap and one highlight; the tiling popover's titles and its glyph and row highlight as docs/specs/tiling.md asks, the menus' header and selection, which the macOS 27 Move & Resize capture shows too; the stack's list rows on MenuItem's metrics. With it, the owner's decision of 2026-10-31 on G7: a ring a surface shows on open after a key only, `Popups.openedByPointer`; step 25: the Dock menu's "Recent Documents" and the Grassfield menu's Recent Items headers are `MenuHeader` rows, and the Dock's clicks open their menus and stacks as the pointer's) | audit §4.6 |
| G18 | Inactive windows change only their lights | the accent sidebar selection, the toolbar title and glyphs stay as in the key window (step 17, measured on macOS 27's inactive windows, audit §3.13: the toolbar title and every ToolButton's glyph at the text colour's `window.inactiveTextOpacity*` 0.28 / 0.32, Settings' sidebar selection the hover ink at `window.inactiveSelectionOpacity*` with the label in the text colour, Preview's rings the dimmed grey; Files and the Store with steps 23 and 24) | audit §3.5 |
| G19 | Third-party title bars are a grey band | #ECECEE (236) on a light window (step 21: the window tokens, warm (ADR-0040), `titlebar.backgroundLight` #FDFCF9 and `backgroundDark` #2B2925, with the toolbar rule under the bar, `titlebar.rule*` black at 0.08 and white at 0.16, one point (D5); the plugin's build and the bar on screen NOT VERIFIED, gates C1–C3 with the integrator) | `tokens.json` `titlebar.backgroundLight` |
| G20 | Motion without a reference | 7 easing types besides linear, no spring, all motion tokens "estimate"; shell and compositor on different curves (step 20: `motion.panel` 650 on `motion.curvePanel`, Q6's stand-in, for the Notification Center's and a banner's slide; `curveEnter` and `curveExit` beside `curveStandard`, one curve per role, the compositor's own (looknfeel.lua), tested equal; the Overview, Search, the stack fan, the switcher and the banners off Qt's ease types; loops, the saver, Files and the Dock with their owners or steps; P3 NOT VERIFIED) | audit §4.1 |
| G21 | Distance-field text | 13 px: 7.7 % less ink than native at 1x, 19.5 % at 2x (T-2 still open) (step 19: the five apps' static text rendered natively, `QQuickWindow::setTextRenderType(NativeTextRendering)` in Settings', Preview's, Files', the Store's and Activity Monitor's `main.cpp`; no app text is scaled or animated; the shell keeps distance fields (Q5 (a)); the owner's side-by-side on the reference screen is the condition for keeping it) | `shots/metrics.txt` |
| G22 | Small finish defects per app | Settings: hand-built buttons without hover, two empty-list styles, 34 literal hairlines (Settings closed by step 15: the (i) and (…) buttons with ToolButton's states, `EmptyListRow`, `apps.borderWidth` for every hairline, the colour well on `TextField` and `Material`, `ErrorNote` in `windowSecondary`, the toolbar's rule once content scrolls under it (D3), three unused tokens removed; Software Update's files with step 26, closed by it: its sheet's two lists on `radius.group`, its page already on the shared pieces); Files: dark wells in Customize Folder (0.14 in the light appearance), no in-view loading (Files closed by step 23: the wells on `Appearance.fillOpacity` with the shared ring, the tags field's ring rounded, the shared `Spinner` (D4, moved from Settings) in a view that has listed nothing after `files.loadingDelay`, the window's secondary colour, keyboard paths for the path bar and the preview pane's actions; after #67 merged, the five secondary-text uses of `FileList.qml` and `ColumnView.qml` and the one of its `PrintSheet.qml` on the window's colour, and the list's sort reached by keyboard through View > Sort By, as macOS); Store: buttons without hover or pressed state, disabled 0.45 against 0.38, three progress indicators across the apps (Store closed by step 24: the app button with the shared push button's hover and pressed inks, its Increase Contrast outline and `material.disabledOpacity` 0.38; `ProgressRing` and `Spinner` in `Grassfield.Ui` (D4), with `MenuPopup`, the Store's and Settings' one menu host (Activity Monitor's copy goes once #86 merges); an empty category says so; the lockup's hairline on `apps.borderWidth` (D5); the sidebar's selection lighter while the window is not key) | audit §4.2–§4.5 |
| G23 | Pixel-grid leftovers | the check box label and the inline pop-up's chevron disc on half pixels (the right-aligned menu shortcuts keep a whole right edge by design, corrected in step 1) (14 of 62 items off the grid, mostly text widths) | `shots/gallery-light-1x-walker.txt` |
| G24 | Gate A2's role table is red on main | `test_contrast_tokens.py` exits 1: 15 file-and-class counts of contrast-relevant colour uses differ from `contrast-roles.json` (13 on 11c9e69); every one is a table out of date, no colour fails; the check is in `scripts/dev/test.sh`, not in `just check-quick` | audit §3.7.5 |

## Decision

### Rules every step follows
1. **One material per role.** Every glass surface names a glass class; a part of a surface (a tail, a plate, a close
   capsule) takes its body's tint. Real blur only.
2. **One radius per role, concentric inside.** An inner shape's radius is the outer radius minus its inset, unless a measured
   macOS value says otherwise and cites it (Search's 17.8-pt row). A role reuses a token of its own role, not another
   surface's (`radius.menu` is not the Settings group radius).
3. **Shared controls first.** A surface uses the `Grassfield.Ui` control when one exists: one push-button shape per size, one
   search field, one menu host, one indeterminate and one determinate progress indicator, one focus ring (`FocusRing`: 3 px,
   outside the shape, `focusRingColor`, keyboard focus only).
4. **One window grammar.** Every app window sets `Appearance.windowSurface`, draws the window neutrals and secondary text,
   an edge-to-edge sidebar, toolbar capsules from shared `toolbar` tokens, and one toolbar edge once content scrolls under it.
5. **A setting reaches every surface.** Increase Contrast outlines every control and frosts every glass; Reduce
   Transparency makes every translucent fill opaque; Reduce Motion turns movement into crossfades of at most 100 ms
   (master-prompt §5.5); Text size follows the answer to Q7. A new surface is added to the matching test.
6. **Tokens only, kept by CI.** No literal design value; UX timings become tokens.
7. **Measured or marked.** A value cites its measurement or stays "estimate"; nothing is claimed on screen without a capture
   (NOT VERIFIED otherwise).

### Decisions taken under the owner's rule ("the closest to macOS 27, no technical step for the end user")
- **D1 Measured per-app values stay.** Settings' 232-pt sidebar with 32-pt rows and the accent selection, Finder's 32-pt
  rows and neutral selection, the App Store's 220-pt sidebar, 38-pt rows and radius 9, Search's 17.8-pt row radius are macOS
  27's own differences between apps, not incoherence. Estimates (Files' 184-pt sidebar, Preview's 28-pt rows) are measured
  before they change.
- **D2 Reduce Motion** keeps the compositor's crossfades (GF-063) and makes the QML do the same: a position, scale or size
  change jumps; opacity and colour crossfade within `motion.reducedMax`.
- **D3 Toolbar edge:** the 1-px rule once content scrolls under the toolbar (Files' behaviour) for every app, until ADR-0024
  phase 3 (the scroll-edge glass) is built and judged by the owner.
- **D4 Progress indicators:** Settings' `Spinner` (indeterminate) and the Store's `ProgressRing` (determinate) move into
  `Grassfield.Ui` beside `ProgressBar`; no new kind.
- **D5 Hairlines:** separators and borders of controls are one point, through one token; glass rims are one device pixel
  (ADR-0024 §2.5).
- **D6 The Store's measured type sizes stay** (the App Store's own type, converted from cap heights), recorded as exceptions
  next to the shared ramp; the shared ramp is named after macOS's text styles in the tokens' sources.
- **D7 Timers stay literals** (debounces, polls, retries); a timing the user perceives (the OSD's hide delay, a notice's
  lifetime) becomes a token.
- **D8 A shell menu leaves the front window key** (the integrator's macOS decision in the second review of #88, 2026-11-02):
  while a menu, a status menu, a popover or the Control Center holds the keyboard, the window that was key keeps its key look
  (step 17's selection, toolbar title and glyphs, and the lights); only another window taking the focus makes it inactive.
  Hyprland withdraws the window's activation as soon as a shell layer takes the keyboard, and Qt follows it, so an app cannot
  tell a menu from another window. The shell says which client looks key in a runtime file, as it already says what the
  plugin offers (ADR-0015 Q4b): `$XDG_RUNTIME_DIR/grassfield-keywindow.json` (`$GRASSFIELD_STATE_HOME/keywindow.json` in a dev
  session), `{"v":1,"pid":…,"appId":…}`, written by `shell/services/KeyWindow.qml` (the rule in `KeyWindowFile.js`: the
  focused window's client, the menu's opener while the Overlay's popup holds the keyboard with a kind that is not a dialog
  and until a window is focused again after it, at most `focusReturn.menuActionWaitMs`; nobody under the lock, over the
  desktop, or while another shell surface or a dialog holds it). `apps/keywindow.h`, made by each of the five apps with its
  engine, holds the app's last focused window key (`Appearance.heldKeyWindow`) while the app has no focused window and the
  file names it; `Appearance.looksKey(window, active)` is what step 17's looks read. No file, an old shell or a malformed file:
  `Window.active` alone, as before. Not covered: third-party apps and the compositor's own window edge and titlebars, which
  follow Hyprland's activation (only the plugin could keep it, for every client: a later step if the owner wants it).
  Rejected: the global menu's opened and closed events (they cover the app menus, not the Control Center or the Dock's menus).

### Steps, in priority order
One pull request each, with `just check`, the tests and captures (`docs/audits/design-polish-2026-10-29/tools/run.sh` for
the shared controls and Settings; `just shot` in the nested session, integrator). "Free" means no frozen file. Sizes: S (a
few files), M (a surface family).

| # | Step | Where | When | Verify | Size | Closes |
|---|---|---|---|---|---|---|
| 0b | **Gate A2's role table:** the 15 undeclared uses of audit §3.7.5 added to the roles that already cover them (exempt ones with their reason), `test_contrast_tokens.py` added to `just check-quick`; the three `shell/security` entries confirmed by the security reviewer (no security code changes) | `tests/visual/contrast-roles.json`, `justfile` | first, now (the menu bar's band fix, fix/bar-tone-video, merged in 1048307 with its own entries) | `test_contrast_tokens.py` exit 0; `just check-quick` fails with a planted undeclared use | S | G24 |
| 1 | **Increase Contrast and pixel grid in the shared controls:** no border around the bezel-less inline pop-up (only its chevron disc), its disc on whole pixels; Toggle, Switch and Slider outlined under Increase Contrast; the check box label on a whole pixel (the menu shortcuts keep their whole right edge: not a defect) | `ui/Grassfield/Ui/ComboBox.qml`, `Toggle.qml`, `Switch.qml`, `Slider.qml`, `CheckBox.qml`; `tests/unit/tst_pixelgrid.qml` and `tst_increasecontrast.qml` | free, now | renders (`tools/run.sh`), unit tests, A2 | S | G8, G9, G23 |
| 2 | **CI guard for literals:** `tests/ci/qml_literals.py` from the audit's tool, run by `just check-quick`; zero literal radius, font size, opacity, geometry value and animation duration; the 20 colours allowlisted per file and timers not counted (the OSD's hide delay was already `osd.hideDelay`; its 1500 is an arming delay after start, logic; the Store's 6000-ms notice lifetime becomes a token after step 3c) | `tests/ci/`, `tests/inventory.json`, `justfile` | free, now | the guard fails on a planted literal | S | rule 6 |
| 3 | **Preview's window and settings:** `windowSurface`, window neutrals in Viewer and Glance, `windowSecondary`, text selection in `highlight`, Increase Contrast and Text size read by the backend and bound (Q7). With step 2's review: the literals guard reads a ternary's branches, an offset to a token, `Layout.*`, declared properties, groups, `scale`, `sourceSize`, literal alphas and named colours, outside JavaScript blocks and object literals; `tst_increasecontrast` grabs a knob in the scene and checks that nothing is outlined with the setting off | `apps/preview/qml/Viewer.qml`, `Glance.qml`, `Theme.qml`, `TextView.qml`, `apps/preview/src/previewapp.{h,cpp}` | free, now | build, unit tests, a render or nested capture | S–M | G11 (part), G12 |
| 4 | **Shell sheets' blur radius** from the dialog's own corner. With step 3's review: the literals guard reads hex in any quotes, a binding's block by the values it returns, the right operand of `&&`, products of numbers alone and objects under an import alias; Preview's PDF file-name row follows Text size | `shell/overlay/Overlay.qml` | free, now | nested capture (NOT VERIFIED here) | S | G2 |
| 5 | **Reduce Motion as crossfades** on the free surfaces: banners and the Notification Center fade instead of sliding, knobs, Overview tiles, Search's height, the stack fan and the OSD jump (the Files tab bar with step 23); the saver's slide crossfade capped; Preview's animated images and Settings' spinner still. With step 4's review: the Overlay's blur corner is `PopupKinds.blurCorner`, run by its test and held to the kinds the Overlay builds on Dialog; the literals guard leaves inner functions out and reads locals, called functions and colours in backticks. Built without the shared helper (each surface reads `Appearance.reduceMotion`) | `shell/notifications`, `shell/overview`, `shell/search`, `shell/overlay`, `shell/osd`, `shell/saver`, `ui/Grassfield/Ui/Toggle.qml`, `Switch.qml`, `apps/preview`, `apps/settings/qml/Spinner.qml` | free, now (a shared helper in `Appearance.qml` after its merge) | unit tests with `reduceMotion`, nested `reduce-motion-compositor.sh` unchanged | M | G10 |
| 6 | **Window edge per appearance (C-4):** border tokens per appearance, pushed by the shell with the appearance as it pushes the blur. With step 5's review: an animated image in Preview waits on its first frame under Reduce Motion with a play control (the integrator's call: Reduce Motion is for the chrome, as macOS's "Auto-play animated images"); the saver keeps its dissolve; a dropped banner and the list's pill jump; the guard reads a local only when it is returned whole; the blur test follows a component's chain of root types | `shell/platform/Compositor.qml`, `Minimized.js`, `tokens.json`, `config/hypr/grassfield/looknfeel.lua` | free, now | a unit test of the call; nested capture of a light window's edge | S–M | G15 |
| 7 | **One focus ring** on the free surfaces: `FocusRing` or `focusRingColor`, outside the shape, keyboard focus only; Clear All in the Notification Center and the Stages tiles on the keyboard | `shell/overlay`, `shell/notifications`, `shell/launchpad`, `shell/overview`, `shell/switcher`, `shell/widgets`, `shell/stages`, `ui/Grassfield/Ui/LinkText.qml`, `WindowLight.qml`; Settings' `ArrangeSheet`, `ColorWell`, `WallpaperSection`, `PrivacyCategoryPage`, `LoginItemsPage` | free, now | unit tests (ring after a key, none after a click) | M | G7 |
| 8 | **Menu grammar:** section headers aligned with the check column; Volume, the tiling popover and the stack list on `PopupMenu`'s metrics (the tiling popover against ADR-0036's spec first) | `ui/Grassfield/Ui/PopupMenu.qml`, `shell/overlay/VolumeMenu.qml`, `TilingPopover.qml`, `StackPopup.qml` | free, now | renders, unit tests | S–M | G17 (part) |
| 9 | **Dark secondary text** in app windows (Q3) | `tokens.json` `color.dark.windowTextSecondary`, `tests/visual/test_contrast_tokens.py` | decided (Q3: #A1A1A6) | A2, renders | S | G13 |
| 10 | **Sheet buttons and radii** (Q1, Q2): the shared `Sheet`'s buttons, its radius and concentric controls; `radius.sheet` and `radius.alert` | `ui/Grassfield/Ui/Sheet.qml`, `tokens.json`, `shell/overlay/Dialog.qml` | radii now (Q2); buttons after the macOS 27 sheet measurement (D-Q1) | renders of a Settings sheet, nested capture of the shell's | S–M | G3, G4 |
| 11 | **One green for "on"** (Q4) | `Toggle.qml`, `Switch.qml`, `Slider.qml` | after the macOS 27 dark check (D-Q4) | A2 (knob 3:1), renders | S | G14 |
| 12 | **Hover and selection roles:** one token per role (control hover, neutral row selection on glass, accent menu selection, grid selection) replacing the multipliers | `shell/overlay/StackPopup.qml`, `shell/overview`, `shell/switcher`, `shell/overlay/TilingPopover.qml`, `tokens.json` | free, now | renders, A2 | S–M | G6 |
| 13 | **Radius roles and concentric shapes:** `radius.group` for Settings' groups, the inner radii of G5, rounded tiling-suggestion thumbnails; the switcher's selection measured first; `radius.dialog` stays (the polkit dialog's, outside this lane) | `tokens.json`, `apps/settings/qml/SettingsGroup.qml` and its readers, `shell/overlay/ForceQuitPanel.qml`, `StackPopup.qml`, `controlcenter/NowPlaying.qml`, `shell/widgets/builtin/nowplaying/NowPlaying.qml`, `shell/notifications/NotificationContent.qml`, `TilingSuggestions.qml` | free, now (Sheet with step 10) | renders | S–M | G5 |
| 14 | **Shared toolbar and search field:** `toolbar.*` tokens (capsule 36, button 34, divider) replacing the borrowed `files.*` and `settings.*`; `RimmedCapsule` on them; `SearchField` as the rimmed 28-pt capsule with a clear button, used by Settings; icon-only `ToolButton`s show their name as a tooltip | `ui/Grassfield/Ui/RimmedCapsule.qml`, `SearchField.qml`, `ToolButton.qml`, `tokens.json`, `apps/settings/qml/Main.qml` | free, now (Files and Store with steps 23 and 24) | renders, unit tests | M | G16 (part) |
| 15 | **Settings finish** (Software Update excluded): `InfoButton` and `MoreButton` on `ToolButton`'s states, the colour well's field and popover on `TextField` and `Material`, one empty-list style, `ErrorNote` in `windowSecondary`, the 34 literal hairlines on the token, content that scrolls under the toolbar with its rule (D3), the glass preview on the class tints and Reduce Transparency, unused tokens removed | `apps/settings/qml/*` | free, now | renders (`settings.py`), unit tests | M | G22 (Settings), G12 (preview) |
| 16 | **Preview's structure:** the edge-to-edge sidebar, toolbar capsules on the shared tokens with 34-pt buttons, scroll bars, the toolbar rule | `apps/preview/qml/Viewer.qml`, `ToolbarGroup.qml`, `ImageView.qml`, `TextView.qml` | free, after step 14 | nested capture | M | G11 |
| 17 | **Inactive windows:** the selection of a window that is not key turns neutral; the toolbar title and glyphs dim; a shell menu or the Control Center leaves the window key (D8) | `ui/Grassfield/Ui/UnifiedToolbar.qml`, `apps/settings/qml/Main.qml`, `apps/preview` | free, now; Files and Store after their merges | renders with `Window.active` false; a macOS 27 capture of an inactive window (NOT VERIFIED until then) | S–M | G18 |
| 18 | **Text size everywhere** (Q7): Preview (done in step 3: its title, search field and PDF file names on the body size) and Files (with step 23); the apps' text tokens follow `textScale` | `tokens.json`, `apps/preview`, `apps/files` | decided (Q7: every app) | unit tests at 130 % | S | G12 |
| 19 | **Native text in the apps** (Q5) | the apps' `main.cpp` (Settings, Preview now; Files, Store, Activity Monitor after their merges) | decided (Q5: the apps' static text) | `shots/metrics.txt` method, the owner's side-by-side | S | G21 |
| 20 | **Motion tokens** (Q6): a panel-and-sheet curve, one easing per role (enter, exit, move), Hyprland's curves aligned with them | `tokens.json`, the free surfaces, `config/hypr/grassfield/looknfeel.lua`, `shell/platform/Minimized.js` | decided (Q6: the 650-ms stand-in) | nested recordings, P3 | M | G20 |
| 21 | **Third-party title bars** (Q8) | `tokens.json` `titlebar.*`, the plugin's theme (nested only, gates C1–C3) | decided (Q8: the window tokens) | nested capture | S | G19 |
| 22 | **Glass classes for every surface:** classes for the Overview band and gallery (0.15) and widgets (0.92); the switcher, tooltips, Stages badges and the About This Wallpaper card on a class; tails and close capsules on their body's tint, the Increase Contrast frost and Reduce Transparency; Material's inner rim stronger toward the top left (ADR-0024 §2.5) and its dark edge raised by Increase Contrast | `Appearance.qml`, `Material.qml`, `Tooltip.qml`, `shell/overview`, `shell/widgets`, `shell/switcher`, `shell/stages`, `shell/overlay/DockMenu.qml`, `StackPopup.qml`, `shell/notifications` | **after the Appearance and Material fixes merge** | A2 per class and appearance, nested captures (blur) | M | G1 |
| 23 | **Files finish:** `windowSecondary`, Increase Contrast and Text size, Customize Folder's wells on `Appearance.fillOpacity`, a rounded tags ring, capsules and search on step 14's pieces, an in-view loading indicator, keyboard paths for the column headers, path bar and preview-pane actions, native text (Q5) | `apps/files` | free now (#41 merged); the Files findings re-measured on main first | renders, unit tests, nested | M | G12, G16, G22 (Files) |
| 24 | **Store finish:** buttons with hover and pressed states and the shared disabled opacity, the shared progress indicators (D4), menu host and search field (28), an empty state on the category page, the hairline token, rings on keyboard focus, native text (Q5) | `apps/store` | **after step 3c merges** | renders (store shots), unit tests | M | G16, G22 (Store), G7 |
| 25 | **Dock, desktop and menu bar:** the Dock shelf's darker outer edge (ADR-0024 §2.5), the Dock menu's "Recent Documents" as a header, one bar-button ring on keyboard focus, the Dock's auto-hide jumping under Reduce Motion, the desktop widgets' scale too (`DesktopWidgets.qml`, the review of step 5), its easings per role, the menu bar's band under Reduce Transparency and Increase Contrast; the desktop icon labels follow the wallpaper tone under them as the menu bar does (dark text without the heavy halo on a bright wallpaper, as macOS; dark labels need a new A2 role over the light wallpapers the tone is chosen for, as the menu bar's dark foreground has, beside today's white-label roles; the integrator's finding of 2026-10-29 on #45, a capture on the owner's machine) | `shell/dock`, `shell/desktop`, `shell/menubar`, `shell/overlay/DockMenu.qml` | **after their fixes merge** | nested | M | G1, G7, G10, G17 |
| 26 | **Software Update panel:** step 15's Settings rules on its three files | `apps/settings/qml/SoftwareUpdate*.qml` | free now (#44 merged) | renders (`settings.py --update`) | S | G22 |
| 27 | **Activity Monitor:** its window built on these rules from the start (a checklist in its step, ADR-0038) | `apps/activity` | at its window step (step 27: the checklist below, "Activity Monitor checklist", with its state on main; into ADR-0038 once #86 merges) | its own review | — | — |
| 28 | **The switch knob's edge with Increase Contrast off** (G9, from the review of step 2): the knob of Toggle and Switch gets the drop shadow that sets the macOS 27 knob apart from a light off track, measured on the reference (a real shadow, in tokens). Until then a white knob is 1.25:1 against its off track on opaque material, and Increase Contrast outlines it (steps 1 and 2) | `ui/Grassfield/Ui/Toggle.qml`, `Switch.qml`, `ui/tokens/tokens.json` | needs the reference measure (F1) | a render on the material, a unit test of the knob's edge | S | G9 (setting off) |

Step 0b and steps 1 to 8 need neither an answer nor a merge (the review's clashes of steps 6 and 20 with #43, and of steps
14, 15 and 17 with #44, are gone: both merged before these steps start). Steps 9 to 11 and 18 to 21 follow the owner's answers of 2026-10-29
("Owner decisions (2026-10-29)" below): step 10's buttons and step 11's colour start with a measurement of the macOS 27
reference the owner named (Q1, Q4); every other answered step can start in this order.

### Activity Monitor checklist (step 27)

Activity Monitor's window follows these rules from its first step (ADR-0038). The checklist goes into ADR-0038's step once #86,
which edits that ADR and the app, merges; until then it lives here. State on main, 2026-10-31 (`apps/activity/qml`):

| Rule | Where it comes from | State |
|---|---|---|
| The window's neutrals and secondary colour (`Appearance.windowSecondary`), never the glass `colors.textSecondary` | Q3, step 9; G13 | done after #86 merged: the seventeen uses of its windows (Main, ProcessList, Inspect, Performance, CPU and App History) |
| The shared toolbar: `UnifiedToolbar`, `RimmedCapsule` on `toolbar.*`, `SearchField` 28 with its clear button | step 14; G16 | done |
| Icon-only toolbar buttons name themselves (`ToolButton.tooltip`), unless the window's own tooltip says more | step 14 | done (Quit Process and the action button carry AM3's richer tooltip) |
| Increase Contrast and Text size read from `accessibility.*` and bound to `Appearance` | Q7, step 18; G12 | done |
| Static text rendered natively | Q5, step 19; G21 | done |
| A window that is not key: the toolbar title and glyphs dim, the selection turns neutral | step 17; G18 | done (`UnifiedToolbar`; the list's selection is emphasized only while the list has the focus) |
| One focus ring, outside the shape, for the keyboard only (`FocusRing`, `KeyFocus`) | step 7; G7 | the shared controls only; check each new focusable item |
| One menu host (`MenuPopup` of `Grassfield.Ui`) | step 24 | done after #86 merged: its own copy is deleted |
| One indeterminate and one determinate indicator (`Spinner`, `ProgressRing`, `ProgressBar`) | D4, steps 23 and 24 | none needed yet |
| Hairlines are one point through `apps.borderWidth` | D5 | done |
| An empty list says so (centred, secondary, inside the list) | step 15 | done after #86 merged: a search that matches no process says "No Results" in the list |
| Motion on the roles' curves (`Appearance.curve`, `curveEnter`, `curveExit`) and crossfades under Reduce Motion | Q6, D2, steps 5 and 20 | no motion of its own yet |
| Tokens only, no literal; A2 for every new text role | master-prompt 5.5; G24 | `just check-literals`, `check-contrast` hold |

## Questions for the owner (answered on 2026-10-29)

**Q1. The buttons at the foot of a sheet.** A Settings sheet ends with 32-pt rounded rectangles; the shell's sheets (About,
Force Quit) with 24-pt capsules; alerts with 28-pt capsules (`shots/gallery-light-2x-controls.png`). The reference library has
no macOS 27 sheet.
- (a) 24-pt push capsules in every sheet, as Settings' rows and the shell's sheets. Pros: one shape for push buttons (43 of
  the 64 `Button`s are push capsules already); no new value. Cons: a smaller target than today's 32 pt in app sheets; the
  macOS 27 sheet is not measured.
- (b) The 32-pt rectangle in every sheet, the shell's included. Pros: larger targets. Cons: a shape no other Grassfield
  control uses next to capsules everywhere else; further from the macOS 26 and 27 controls.
- (c) 28-pt capsules, as alerts, in every sheet and alert. Pros: one shape for every dialog button, a middle size. Cons: a
  third height next to Settings' 24-pt rows inside one window.
- **Recommendation: (a),** checked again when a macOS 27 sheet capture exists.
- **Owner's answer (2026-10-29):** « Il faut la même que sur Mac OS 27 » ("the same as on macOS 27"): see D-Q1.

**Q2. The corner of sheets and alerts.** Windows have one corner: Hyprland's 20 at power 2.6 has the 45° point of a 16.0-pt
circle (macOS 27 measures 16.6; ADR-0024). Sheets are 26 and alerts 24 (macOS 26 values), 8–10 pt rounder than the window
under them.
- (a) The window's radius for sheets and alerts too (16 in QML, the circle that matches the window corner's 45° point). Pros:
  "one radius for every window", as macOS 27 does for every window measured, the Force Quit panel among them. Cons: not
  measured on a macOS 27 sheet or alert.
- (b) Keep 26 and 24. Pros: measured, on macOS 26. Cons: the sheet's corners stand out against its window's.
- (c) Wait for a macOS 27 sheet and alert capture from the owner. Pros: certainty. Cons: the step waits.
- **Recommendation: (a).**
- **Owner's answer (2026-10-29): (a),** the window's radius for sheets and alerts.

**Q3. Secondary text in dark app windows.** Today #DCDCE4: 10.67:1 on the window against 13.36:1 for the primary text, so
secondary lines read like titles (`shots/settings-desktop-dark-2x-crop.png`). Every option keeps A2 (4.5:1).
- (a) #A1A1A6, about white at 0.55 over the window: 5.66:1 on the window, 5.06 on groups, 6.11 on the sidebar. Pros: a
  visible hierarchy (the text has 2.55 times its luminance), close to macOS's secondary label. Cons: not measured on a dark
  macOS 27 capture; a smaller margin above 4.5 on groups.
- (b) #B4B4BA: 7.05, 6.31 and 7.62. Pros: a wide margin. Cons: a weaker hierarchy (luminance ratio 2.0).
- (c) Keep #DCDCE4. Pros: the highest contrast. Cons: no hierarchy.
- **Recommendation: (a).**
- **Owner's answer (2026-10-29): (a),** #A1A1A6.

**Q4. One green for "on" in the dark appearance.** Switches and slider fills use the bright green #4FB36B; checkboxes,
radio buttons, default buttons and selected rows the deeper #2E8049 chosen for white text (owner decision of 2026-10-26).
- (a) Switches and slider fills on #2E8049 too (each accent's dark selection fill). Pros: one green for "on"; the white knob
  goes from 2.63:1 to 4.88:1 (WCAG 1.4.11), and from 1.82–2.77:1 to 4.85–4.89:1 for every other accent but yellow and
  green. Cons: a darker switch than macOS's bright one; with the yellow or the green accent the knob stays under 3:1 (2.02:1
  on #E0B000, 2.52:1 on #6DB53C), because their pairs keep dark marks (green since ADR-0040 step 1c, the owner's light Green
  of 2026-10-30).
- (b) Keep both greens. Pros: brighter switches. Cons: two greens side by side in one Settings row; the knob under 3:1.
- (c) Checkboxes and radio buttons on #4FB36B with a dark mark. Pros: one bright green. Cons: breaks white-on-accent (F1,
  2026-10-26) with a dark checkmark, which macOS never draws.
- **Recommendation: (a).**
- **Owner's answer (2026-10-29):** « Même chose que sur Mac OS 27 » ("the same as on macOS 27"): see D-Q4.

**Q5. Native text rendering in the apps (T-2, open since 2026-10-26).** Distance-field text carries 7.7 % less ink than
native glyphs at 1x and 19.5 % less at 2x (13 px), so it reads greyer and softer than macOS text.
- (a) Native rendering for the apps' static text (Settings, Files, Preview, the Store, Activity Monitor); distance fields
  stay where text is scaled or animated (Dock labels, Overview). Pros: closer to macOS's weight where reading happens; one
  line per app. Cons: apps and shell rasterise text differently; judged on the owner's screen first, as decided on
  2026-10-26.
- (b) Native rendering everywhere, the shell's static text included. Pros: uniform. Cons: more surfaces to check, and
  shell text that moves must be excluded one by one.
- (c) Keep distance fields. Pros: no change. Cons: the gap stays.
- **Recommendation: (a),** after the side-by-side on the owner's screen.
- **Owner's answer (2026-10-29): (a),** native rendering for the apps' static text.

**Q6. Motion of panels and sheets.** No motion was ever recorded on a Mac (2026-10-26 decision 6); today panels use 120,
220 and 350 ms on one curve, and nothing springs.
- (a) Apple's documented default spring as a fixed-duration stand-in for panels and sheets (650 ms, cubic-bezier 0.24, 0.24,
  0.15, 1.04), menus still instant, small controls unchanged. Pros: no recording needed; Apple's own default for app
  animations. Cons: not measured on the system's panels; P3 must hold for longer animations.
- (b) The owner records five clips on a Mac (a menu, Control Center, Notification Center, Spotlight, a sheet) and the tokens
  follow them. Pros: exact. Cons: needs a Mac and the owner's time.
- (c) Keep today's durations; only one easing per role. Pros: cheapest. Cons: motion stays the least macOS-like trait.
- **Recommendation: (a),** calibrated later with (b) if a Mac is at hand.
- **Owner's answer (2026-10-29): (a),** Apple's default spring as a 650-ms stand-in.

**Q7. How far Text size reaches.** Today: the shell's panels, Settings and the Store; not Files or Preview; menus never.
- (a) Every Grassfield app (Files and Preview too); menus keep their size, as now. Pros: one setting behaves the same
  everywhere. Cons: Files' list and icon metrics need checking at 130 %.
- (b) Keep today's reach; the pane already says what it scales. Pros: no work. Cons: two apps out of five ignore it.
- **Recommendation: (a).**
- **Owner's answer (2026-10-29): (a),** every Grassfield app.

**Q8. Title bars of third-party windows.** The compositor draws them #ECECEE in the light appearance and #28282C in the dark
one; Grassfield's own windows are #FFFFFF and #292929, and the macOS reference draws the window's own colour (visual-tahoe,
low confidence).
- (a) The window tokens: #FFFFFF and #292929, the title bar told apart by the hairline under it. Pros: coherent with every
  Grassfield window and with macOS. Cons: a white bar above an app whose content is grey looks detached.
- (b) A near-white #F6F6F6 (dark unchanged). Pros: softer above grey apps. Cons: still a band, a value of its own.
- (c) Keep #ECECEE. Pros: no change. Cons: the grey band the 2026-10-25 audit noted.
- **Recommendation: (a).**
- **Owner's answer (2026-10-29): (a),** the window tokens #FFFFFF and #292929.

## Owner decisions (2026-10-29)
Asked with AskUserQuestion after step 0 was written; the answers verbatim where the owner wrote their own.

| | Answer | What the steps do |
|---|---|---|
| Q1 sheet buttons | « Il faut la même que sur Mac OS 27 » | D-Q1 below (step 10) |
| Q2 sheet and alert corners | (a) the window's radius | step 10: `radius.sheet` takes the window's circle-equivalent (16), inner controls concentric. ADR-0024's note of 2026-11-04: the window measured 19.8 at rounding 20, not 16.0 (Hyprland draws rounding x power / 2); at the new rounding 17 it measures 16.7, and `radius.sheet` follows it: 17. Alerts: the owner's decision of 2026-10-31, once macOS 27 alerts were measured at 25.6–27.3 (Mail, Finder's Empty Trash; audit §3.8), is 26, as macOS 27, over this answer's 16, which assumed one radius |
| Q3 dark secondary text | (a) #A1A1A6 | step 9: `color.dark.windowTextSecondary` #A1A1A6, A2 asserted on window, group and sidebar Done (G13 closed): `#A4A19C`, the owner's #A1A1A6 warm as ADR-0040 makes every neutral; 5.64:1 on the window, 5.04 on a group, 6.09 on the sidebar, tested with the text at twice its contrast; the public macOS 27 dark capture `Apperance-Dark-Green` measures its secondary text at #9F9F9E to #A2A2A2 (5.2 to 5.5:1), so the open point is measured |
| Q4 "on" in the dark appearance | « Même chose que sur Mac OS 27 » | D-Q4 below (step 11) Step 11 done (G14 closed): D-Q4 (a), switches and slider fills take the selection colour, the fill of a checked box and a default button, in both appearances and for every accent; the white knob holds 4.85:1 or more there, and on the yellow and green fills, which keep dark marks (2.02:1, 2.52:1), it is outlined in their mark colour (`Accent.knobOutlined`, `control.knobMinContrast` 3). The public macOS 27 dark captures (`Apperance-Dark-Green`, `-Blue`) show one fill for the menu highlight, the selected row and the swatch (#62BA46 for green, white text); their Settings window is inactive, so no accent switch was measured there |
| Q5 native text | (a) the apps' static text | step 19: native rendering in Settings and Preview first, then Files, the Store and Activity Monitor after their merges; distance fields where text is scaled or animated; the owner's side-by-side on the reference screen before it is kept (decision of 2026-10-26) |
| Q6 motion | (a) Apple's default spring as a 650-ms stand-in | step 20: a panel-and-sheet curve token (650 ms, cubic-bezier 0.24, 0.24, 0.15, 1.04); menus stay instant; P3 measured |
| Q7 Text size | (a) every Grassfield app | step 18: Files and Preview follow Text size; menus keep their size |
| Q8 third-party title bars | (a) the window tokens | step 21: `titlebar.backgroundLight` #FFFFFF, `backgroundDark` #292929, a hairline under the bar |

- **D-Q1 (the owner's answer, read by the integrator).** Sheets take the push buttons macOS 27 draws in its sheets: shape,
  height, width rule and placement. The reference library holds no macOS 27 sheet (C-2), so step 10's buttons start by
  measuring one: macOS 27 release captures of a sheet found by web research (data only, never stored in the repository, as in
  `docs/audits/ui-finesse-2026-10-25.md` §7), or a capture from the owner. Until that measurement exists, step 10 changes
  only the radii (Q2) and the buttons keep today's shapes. The measured shape then applies to the shared `Sheet` and to the
  shell's sheets alike (one grammar), and alerts follow the macOS 27 alert if the same source shows one.
- **D-Q4 (the owner's answer, read by the integrator).** macOS draws switches, checkboxes, radio buttons and slider fills in
  one accent fill with white marks, in both appearances (ui-finesse §7.2: white text on the accent in the dark menu, F1).
  Grassfield's fill that holds white marks in the dark appearance is the selection colour (#2E8049 for the green, the derived
  shade per accent of 2026-10-26), so "the same as on macOS 27" is option (a): switches and slider fills move to it. Step 11
  first checks this on the dark macOS 27 release captures (a switch and a checkbox side by side); if they show two fills, the
  step follows what they show and records it here. The fill is each accent's dark selection colour: the white knob reaches
  4.85–4.89:1 for every accent but yellow and green, whose pairs keep dark marks (green since ADR-0040 step 1c); there the
  knob stays at 2.02:1 and 2.52:1, and step 11 gives it the outline Increase Contrast draws (step 1) or records the limit.

## Coordination with the identity lane (ADR-0040, pull request #46)
The integrator's review named nine overlaps. Whichever pull request merges second rebases; the owner of each is:

| Overlap | Owner | The other lane |
|---|---|---|
| The greens: this Q4 and step 11 ↔ IQ-B3 (the default accent named "Grassfield") | ADR-0040 owns the accent palette (`color.accent*`, the default's name and swatch) | this lane owns which controls read the accent and which the selection fill |
| About: steps 4 and 10 (the shell's sheets) ↔ IQ-B4 (About as a small window), IQ-B1 (the glyphs of `NoticeDialog` and `ConfirmDialog`) | ADR-0040 owns About This Computer's form and the dialogs' glyphs | this lane owns `Dialog`'s and `Sheet`'s grammar (radius, buttons, blur radius); if About becomes a window, steps 4 and 10 no longer touch it |
| `looknfeel.lua`, `windows.lua`, `Compositor.qml`: steps 6 and 20 ↔ ID-2, ID-4, ID-9 | ADR-0040 owns the session's ground colour, first frame and transitions | this lane owns the window border colour per appearance and the compositor's animation curves |
| Motion tokens: Q6's roles ↔ the session and lock fades | this lane owns `motion.*` (the roles of panels, sheets, controls) | ADR-0040 owns `session.*` and `lock.*` fades, which name a `motion` role where one fits |
| `shell/saver` | ADR-0040 owns the saver's transitions (ID-8) | step 5 only gates its slide crossfade under Reduce Motion |
| Settings' Appearance and Wallpaper pages | ADR-0040 owns the wallpaper page and the accent row | this lane owns the shared controls on them and the glass preview (step 15) |
| `GrassfieldArtwork.qml`'s colours: step 2's allowlist ↔ ID-1 (artwork tokens) | ADR-0040 | step 2's guard drops them from its allowlist when ID-1 lands |
| The Dock's and menu bar's auto-hide: step 25 ↔ ADR-0040 step 6 | ADR-0040 owns the reveal at login | this lane owns Reduce Motion and the easing of auto-hide |
| `tests/visual/test_contrast_tokens.py` and `contrast-roles.json` | this lane owns the role table's repair (step 0b) | ADR-0040 adds the roles of its own surfaces (lock scrim bands) |
| The neutrals: ADR-0040's warm neutrals (the owner, 2026-10-30) ↔ ADR-0024's greys, Q3, Q8 and step 21 | ADR-0040 owns the neutrals' warmth (hue 85, chroma 0.0075 in OKLCH, each lightness kept) | this lane owns which roles read them and the glass classes; the window tokens Q8 and step 21 name read warm (`#FDFCF9`, `#2B2925`) |

The owner answered Q3, Q7 and Q8 directly on 2026-10-29, where the review would have had the integrator decide them under
the macOS model; the answers are the options that model gives. Q4 was answered before IQ-B3 is asked; IQ-B3 changes the
palette, not which controls read it.

## Review history
- **Integrator review of step 0 (independent opus, 2026-10-29): FAIL, one MAJOR, four MINORs.** Accuracy: 19 of 20 claims
  exact.
  - MAJOR: `radius.dialog` is used by the polkit dialog (`shell/security/polkit/AuthAgent.qml:250, :316`, `AuthDialog.qml:24`),
    so step 13 no longer removes it. Every "unused" or "rename" claim was checked again over the whole tree, `shell/security`
    included: the three unused Settings tokens hold; "the shared `FocusRing` is used once in the shell" now says outside
    `shell/security`; `SearchField` is used by no surface (only by unit tests).
  - MINOR: the clashes with #43 and #44 are gone (both merged); Q4 now gives the yellow accent's 2.02:1; the audit says what
    the render tools need (and that Qt's `offscreen` platform is not a substitute); the STATE key is 108, above main's 106 and
    the open pull requests' 107.
  - Also in scope: gate A2's role table, red on main: audit §3.7.5 lists the 15 entries (13 on 11c9e69, two more from the
    startup-settle fix), each a table out of date; step 0b repairs it and wires the check into `just check-quick`.
  - Coordination with #46: the section above.
- **Integrator review of #88, round 2 (2026-11-02): two blocking items.** Main (1b33ef24) merged in, the request socket
  resolved as #90's integration did (one socket, `what` "blur" | "edge" | "ground"); D8 above for the key look while a shell
  menu or the Control Center is open (nested: Settings' selection and lights went inactive, 195E3F to E4E2DD and E5534B to
  D4D1CC).

## macOS reference
- macOS 27: one window radius, edge-to-edge sidebars, bars with a rule once content scrolls, white text on the accent, its
  per-app sidebar metrics (System Settings, Finder, App Store), measured on release captures (ADR-0024, ui-finesse §7,
  f1-macos27.md, settings-parity and store audits).
- macOS behaviour, not measured here: a window that is not key shows an unemphasized (grey) selection and dimmed toolbar
  items; Reduce Motion replaces motion with dissolves; Increase Contrast outlines controls; toolbar items show their label as
  a tooltip. Each step that relies on one of these confirms it on a capture or marks it NOT VERIFIED.

## Alternatives rejected
- **One large "design system" pass.** Against the brief (one pull request per step) and against the frozen areas; reviews
  would not see the change for the rewrite.
- **Aligning every app on one app's measured values** (one sidebar width, one row pitch). macOS 27's apps differ; copying
  one would move Grassfield away from each of the others (D1).
- **Waiting for every frozen area before starting.** Steps 1 to 8 touch none of them.
- **New per-surface tokens for every hover multiplier.** Step 12 names roles instead; a surface picks a role.

## Consequences
- Tokens: per-appearance window border tokens, `toolbar.*`, `radius.group`, role fills for hover and selection, the UX
  timings, the glass classes of step 22, the dark secondary and sheet values (Q2, Q3); removed: the three unused Settings tokens of
  audit §4.2 (`radius.dialog` stays: the polkit dialog uses it). Each with its source.
- Code: the role table first (step 0b), the shared controls next (steps 1, 10, 11, 14), then the surfaces; the areas still
  frozen after their merges (steps 22, 24, 25; steps 23 and 26 are free since #41 and #44 merged).
- Tests: gate A2's role check in `just check-quick`, `tst_pixelgrid` and an Increase Contrast case, a CI guard for literals, A2 cases for every new role or class, unit
  tests for Reduce Motion and focus rings; `tests/visual` captures per step (nested, integrator).
- Gates: A1 (keyboard: steps 7, 23), A2 (every colour step), F1 (the owner's side-by-side), P3 (steps 5, 20, 22), C1–C3 (step
  21, plugin).
- Specs: `docs/specs/ui.md` gains the rules above when step 1 lands; each step updates its surface's spec.
- Legal: nothing new; no Apple asset or name; the sidebar tile colours stay on the legal-review list (2026-10-26).

## Evidence
- Report: `docs/audits/design-polish-2026-10-29.md`.
- Captures and logs: `docs/audits/design-polish-2026-10-29/shots/` (the shared controls in both appearances, with and without
  Increase Contrast, at 1x and 2x; Settings > Appearance light, dark and with Increase Contrast; Desktop & Dock dark at 2x;
  Accessibility > Display; the text lab; `metrics.txt`, `corners.txt`; the pixel-grid walker and the control sizes).
- Tools: `docs/audits/design-polish-2026-10-29/tools/` (`run.sh`, `gallery.qml`, `qml-literals.py`) and the 2026-10-25 tools
  they reuse.

## Amendment to ADR-0039 (design polish), step 17 — where the key-window file lives

Date: 2026-11-19 · Status: accepted (2026-11 audit, finding H1)

## Change
The key-window file the shell writes for the apps moves from `$XDG_RUNTIME_DIR/grassfield-keywindow.json` to
`$XDG_RUNTIME_DIR/grassfield/keywindow.json` (a dev session keeps `$GRASSFIELD_STATE_HOME/keywindow.json`). Format and rule
are unchanged (`shell/services/KeyWindowFile.js`).

## Why
Each app watches the file's directory, because the shell replaces the file atomically and a watch on the file goes with the
old inode. With the file directly in `$XDG_RUNTIME_DIR`, every entry any program created or removed there (sockets, locks,
pid files: Wayland, PipeWire, D-Bus, systemd, browsers) made every running Grassfield app open, read and parse the file.
Grassfield's own runtime folder (0700, already shared by the menu bridge, the prompter, the security service and the
capture notice) changes rarely.

## Consequences
- `apps/keywindow.h` watches `$XDG_RUNTIME_DIR/grassfield`; while that folder does not exist yet it watches the runtime
  directory and lets it go as soon as the folder appears.
- The shell writes the new path (`KeyWindowFile.path`); the folder must be 0700 (made with that mode by whoever comes first).
- Line 109 of ADR-0039 ("`$XDG_RUNTIME_DIR/grassfield-keywindow.json`") reads `$XDG_RUNTIME_DIR/grassfield/keywindow.json`.
