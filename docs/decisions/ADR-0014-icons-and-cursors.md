# ADR-0014: Icon appearance modes with live tint, and Grassfield's own cursor set
Status: Accepted (owner delegation D-5, 2026-10-23; status before acceptance: Proposed (owner request 2026-10-19; applied provisionally)) · Date: 2026-10-19 · Decider: owner
(WhiteSur was dropped on 2026-10-21, ADR-0017 amendment.) See ADR-0017 for the WhiteSur distribution, the session theme selection and the Apple-logo guard (it supersedes the "pragma / QT_ICON_THEME" plan here).

## Context
The owner wants icons and cursors as Grassfield capabilities: icons with a live tint like the macOS 26 icon appearance
modes (Default, Dark, Clear, Tinted) and Material You themed icons, and Grassfield's own cursor set with an adjustable
accent and size. Owner decisions (2026-10-19, the maintainers' project log):
- Base icon theme for the internal phase (superseded: WhiteSur was dropped on 2026-10-21, the base is now Grassfield's own icons, Breeze, Adwaita, hicolor, ADR-0017; the text that follows is the history): WhiteSur (third-party, GPL-3.0, a macOS-style theme), shipped as a package
  dependency and never vendored into this MIT repository; a designer replaces it with Grassfield's own set in 6–8 months.
  Apple's own icons are never used (hard rule). docs/legal/visual-review.md E27 must be reviewed again before any
  public release.
- Cursors: drawn by Grassfield now (vector), accent and size adjustable.

Facts (research 2026-10-19, read-only):
- Quickshell 0.3.1 `IconImage` is a thin wrapper over a QtQuick `Image` and exposes it (`backer`), and
  `Quickshell.iconPath` resolves theme icons (`/usr/lib/qt6/qml/Quickshell/Widgets/IconImage.qml`, quickshell-core.qmltypes).
  Qt 6.11 ships `MultiEffect` (colorization, saturation, brightness, contrast) and `qsb` (`/usr/lib/qt6/bin/qsb`) for
  custom shaders.
- Third-party icons have no separate glyph layer (unlike Android's monochrome layer or Apple's per-mode layers): a tint
  on arbitrary icons is an approximation (luminance mapped to a two-tone ramp of the tint colour, alpha kept).
- hyprcursor 0.1.13: a theme is `manifest.hl` plus one folder per cursor (`meta.hl`: hotspot, overrides, sizes), PNG or
  SVG (SVG is size-independent), built with `hyprcursor-util --create`; Hyprland switches theme and size at runtime
  (`setcursor`); XWayland, GTK and Qt read XCursor themes (fallback needed). Adwaita lists ~35 CSS cursor names; legacy
  X11 aliases (left_ptr, hand2, xterm, watch, fleur, sb_h/v_double_arrow…) keep old toolkits working.

## Options
Icons:
1. **Live tint in the renderer:** one shared `TintedIcon` component (ui/Grassfield/Ui) used by every Grassfield surface
   that shows an app or file icon (Dock, Apps panel, Search, desktop, Files, Preview), applying the mode with a GPU effect.
   No files written; switching is instant.
2. Generate a tinted copy of the whole icon theme on disk (~10k files) on every change; every app sees it.
3. Both: 1 for Grassfield surfaces now, 2 later for third-party apps.

Cursors:
A. **Grassfield SVG sources → hyprcursor theme (SVG) + XCursor fallback built at package time; a custom accent or size
   regenerates the theme into the user's data directory and switches to it.**
B. A fixed palette of prebuilt accent variants only.

## Decision (proposed)
- **Icons: option 3, phased.** Phase 1 = option 1: `TintedIcon` with modes `default` (unchanged), `dark`, `clear` and `tinted`,
  implemented with a custom `qsb` fragment shader (`ui/Grassfield/Ui/shaders/icon.frag`): MultiEffect (colorization,
  saturation, brightness, contrast) could not reach the macOS 26 look (a white plate only went from 248 to 210 in Dark; Tinted
  gave a bright tint-coloured plate), so the shader draws a plate and recolours the artwork per mode (algorithm and limits:
  docs/specs/ui.md, "Icon shader").
  **System plate for every icon (owner decision 2026-10-20, replaces the plate-detecting design of 2026-10-19; macOS model:
  an icon that is not made for a mode gets the system plate, none is analysed):** in `dark`, `clear` and `tinted` every
  app or file icon is drawn scaled down (`iconMode.sysGlyphScale` 0.72) on a squircle plate (`sysPlateInset` 0.04,
  `sysPlateRadius` 0.225) that is graphite in Dark, glass in Clear (light glass on a dark material, smoked glass on a light one,
  over the bare wallpaper and at material transparency 0.8 and above) and tinted in Tinted, with a thin edge highlight that scales
  with the icon size (at least 1.5 px, fading below 48 px). The artwork is recoloured by a fixed transform per mode that
  depends on the pixel alone: Dark darkens and slightly desaturates it and lifts very dark parts so they separate from the
  graphite (colour identity kept), Clear turns it into monochrome ink (light in the dark appearance, smoked in the light one)
  whose opacity follows its luminance, Tinted maps its luminance onto a two-tone ramp of the tint. There is NO per-icon
  analysis: no probes, no clustering, no plate or stroke detection, no analysis pass. This is one cheap fragment shader (a
  few texture reads), so it compiles in milliseconds, costs the same on every icon and cannot misread an icon (the previous
  design's halos, wedges and slow cold compile came from guessing). Accepted cost: an icon's own plate is no longer kept,
  so a macOS-style icon shows its plate inside the system plate, as macOS shows non-conforming icons. The folder colour
  (below) recolours the artwork only, not the system plate.
  **Small icons (integrator decision 2026-10-22, the macOS model):** the modes apply only from `iconMode.minSize` (24 px) up; below it
  (Files rows and sidebar, Force Quit rows, the Overview pill, the Dock's minimized badge) every mode draws the Default artwork, because a plate and a recolour made small file-type icons the
  same tile (docs/specs/ui.md, "Small icons keep the Default artwork"). Known issue: the first draw of about 100 effects in the Apps panel
  makes one slow frame per opening in the opt-in effect modes (docs/specs/ui.md).
  Effects exist only when the mode is not `default` and only for icons that are shown: one effect item per visible icon
  (not one shared pass per surface: a container layer would redraw labels, highlights and indicators through the effect). Phase 2 (later, own review):
  a generated tinted theme for third-party apps, regenerated in the background.
- Settings keys (settings contract, versioned): `icons.mode` (`default|dark|clear|tinted`, default `default`),
  `icons.tint` (`accent` or `#rrggbb`, default `accent`). (Implemented 2026-10-19 under `icons.*` because `appearance` is
  already a string key in contract version 1.) Settings › Appearance gets the mode and tint controls (macOS 26
  layout). Folder colours (owner request 2026-10-19) are a separate step, `icons.folderColor` (`theme|accent|#rrggbb`, default `theme`) and a per-folder colour and symbol (docs/specs/ui.md, docs/specs/files.md), so the mode effects stay untouched. The shell and Grassfield apps react live.
- Base theme: Grassfield sets the icon theme name for its session and for the shell (Quickshell's IconTheme pragma or
  `QT_ICON_THEME`/environment, whichever the installed version supports — verify), with (then) WhiteSur first and the
  freedesktop fallback chain (`hicolor`, then the system theme) for missing icons. Packaging (then): WhiteSur was a dependency of
  the session package with its licence noted in THIRD_PARTY.md; never copied into the repository. Dev sessions use it
  only if the owner installed it.
- **Cursors: option A.** `branding/cursors/` holds the original SVG sources (CC-BY-SA-4.0 like the other Grassfield
  assets, drawn for Grassfield, macOS-like proportions without copying macOS artwork): the CSS cursor names plus legacy
  aliases; a build step (`hyprcursor-util --create`, XCursor PNG sizes 24/32/48/64/96 through the existing build tooling)
  produces `grassfield-cursors`. Settings > Accessibility > Pointer (macOS model: size slider, fill and outline colour).
  Implemented: the size and the colours. The shell asks the compositor for the size with Hyprland's own
  `setcursor <theme> <size>` request on its own instance's request socket, a live redraw follows through the compositor
  capability `cursor-refresh` when the plugin has it (gfc/1 verb `hl.plugin.grassfield.cursor_refresh()`, plugin
  0.7.0-cursor: Hyprland's last named shape re-applied with force, so a pointer that does not move is drawn at the new
  size with the same shape and at the same place; never while it is hidden or a client draws its own cursor surface;
  `docs/specs/compositor.md` FR39-FR40), and the applications the shell starts get `XCURSOR_SIZE` and
  `HYPRCURSOR_SIZE` in their environment; running applications keep their size (documented limit).
  **Colours (owner decision 2026-10-19, macOS Accessibility > Display > Pointer: "Pointer outline color", "Pointer fill
  color", "Reset Color"; any colour is allowed, no contrast guard, as macOS):** the settings keys `pointer.outlineColor`
  (default `#ffffff`) and `pointer.fillColor` (default `#000000`), the two placeholders of the SVG sources. For any other
  pair the shell regenerates the theme: `branding/cursors/build.sh --name grassfield-cursors-custom --out <icons dir>
  --outline ... --fill ...` (SVG recolour, `hyprcursor-util --create`, XCursor PNG sizes) in a Process off the UI thread,
  debounced while a colour well is dragged (the final pair is always built), one build at a time (a newer pair terminates
  the running one), written atomically (build into a temporary directory, rename), then `setcursor
  grassfield-cursors-custom <size>` and the `cursor-refresh` redraw; "Reset Colour" switches back to `grassfield-cursors`
  and deletes the custom one. **The wanted theme is derived from the stored colours only, never from the session
  environment** (fix pass after review: when `cursor.lua` chose the custom theme at login because it existed on disk,
  Reset Colour was a no-op): `cursor.lua` always starts a real session with `grassfield-cursors`; the shell switches to the
  custom theme when its settings are read and the stamp (`colors`, written by build.sh inside the theme) names the stored
  colours, rebuilds when it does not, and at startup with default colours sends `grassfield-cursors` and deletes any
  custom theme. The theme on disk is identified by its stamp, not by a build counter; a build is its own process group
  (`setsid`) and is stopped as a group. A failed or impossible build (missing tool, no script, no directory) leaves the pointer as it is
  and the reason is shown in Settings. **`python`, `librsvg` (rsvg-convert) and `hyprcursor` (hyprcursor-util) are
  runtime dependencies of `grassfield-desktop`** (`depends=` in `packaging/arch/PKGBUILD`); the script, the sources and
  the table are installed under `/usr/share/grassfield/cursors`. The icons directory is `$XDG_DATA_HOME/icons`, else
  `$HOME/.local/share/icons` (hyprcursor and XCursor search `$HOME/.local/share/icons` and `$XDG_DATA_DIRS`); a dev
  session writes under `.dev/share/icons` only and refuses to build without that directory. Dev: only the nested instance
  is ever addressed.

## Amendment 2026-11-08 (R7-REQ-13, owner decision: icon modes at their floor before 1.0, no exemption)
The A2 exemptions of the icon modes (18 cells, 1.52 to 2.82:1) are removed and `tests/fixtures/icons/a2-limits.json` is empty (no acceptance, no exemption). Three changes, all tokens of the `iconMode` group, none touching Default, glyphs, folders or the plate: (1) the Tinted ramp of the dark appearance is `tintedRampLowDark` 0.62 (was 0.55) and `tintedRampHighDark` 1.0 (was 0.8), which lifts the tones of plate-less artwork (kdenlive, obs, the terminal) out of a dark material while keeping rule N for the yellow tint (a first value, 0.70 / 0.96, passed the five cells and failed rule N on the GPU of 2026-11-09); (2) a **tile tone** for own-tile icons (full-bleed tiles such as basecamp) in the light appearance: while the material is solid the pixels below the darkest material (`tileDarkenPivot` 0.62) are darkened (`tileDarkenExponent` 1.75), never towards the material; (3) a **rim** on every tile in the dark appearance (a halo outside the tile `darkRimWidth` 0.04 of the box, at least a device pixel, drawn behind it, plus `darkRimInnerPx` 0.5 inside; `darkRimStrength` 1.0, `darkRimLuma` 0.95; none over the bare wallpaper; a rim of 1 px inside reached rule I's ring at 24 px on the GPU), the macOS specular edge, which changes no inner tone (rules I, S, N). The plates over the dark selection fills of the app follow the selection colours (`clearPlateAlphaAccent` 1.0, `darkPlateLumaOnDarkAccent` 0). A lift of the bright tones in the dark appearance was tried and removed: on the GPU it cost rule I and S cells. Where Default itself is below 3:1 (basecamp at transparency 1.0: 1.92:1) the floor stays 0.9 of Default's. Numbers, the model they come from and what is not a GPU measurement: docs/specs/ui.md, "R7-REQ-13". Verification is `just test-icons`.

## Consequences
- New shared component, a committed compiled shader (`scripts/dev/build-shaders.sh`, checked by `just check`) and settings keys; every icon call site moves to `TintedIcon` (one effect item per visible icon).
- New asset folder `branding/cursors/` and build steps (hyprcursor-util and XCursor generation as build dependencies).
- (Historical, WhiteSur dropped 2026-10-21) GPL-3.0 WhiteSur was a separate package; the ISO (M6) must ship its source offer and licence; public release needs the
  E27 legal review again.
- Limits: tinted third-party icons are approximations; running GTK/Qt apps keep their cursor until restarted.
