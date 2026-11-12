# ADR-0040: Grassfield identity: wallpapers, brand, lock screen and session transitions
Status: Accepted (the owner answered the twelve questions and B-5 on 2026-10-29: "Owner decisions (2026-10-29)", with the
integrator's conditions for the four non-recommended choices, W1 C, W2 C, W3 A and L1 C). Step 0 merged (pull request
#46, e16fa8c), steps 1a, 1b, 1c and 1d merged (pull requests #52 a5488a6, #55 12bcda9, #69 837dd2b, #76 244f16a); the
owner's brand green and warm neutrals of 2026-10-30 merged (#71 56befa2, #73 5229fd3), their GTK follow-up in #79; step 7
(the exit) under way. Every other choice follows the owner's rule of 2026-10-28 ("the closest to
macOS 27, no technical step for the end user") and is listed in "Decisions taken under the owner's rule" (ID-1 to ID-21), which the
owner can revisit. Revised after the integrator's opus review of
b44d17e (FAIL: two MAJORs, five MINORs) and again after the re-review of ed21d46 (FAIL: one MAJOR, one MINOR, two
NITs), and after the review of step 1a's 6c310a8 (FAIL: one MAJOR, one MINOR, three NITs), answered in "Review
history"; each changed place says which review. · Date: 2026-10-29 · Decider: owner (IQ), integrator (merge; ID under the rule) · Number: 0040
(0039 is the design-polish ADR, pull request #45, merged as e03c859; the open pull requests #47 and #48 add none)

This ADR proposes one identity for Grassfield across its wallpapers, its brand (mark, name, accent, About, app icons),
its lock screen and every session transition. The audit it rests on is `docs/audits/identity-2026-10-29/audit.md`
(findings W-1 to W-12, B-1 to B-12, L-1 to L-7, T-1 to T-17, with file and line). The mockups are SVG files in
`docs/audits/identity-2026-10-29/mockups/`, written by `mockups.py` next to them; they are design documents, never
shipped. Legal points are marked "needs legal review" (master-prompt §14); none is a conclusion.

**Read with ADR-0039 (design polish, merged as e03c859, the owner's answers of 2026-10-29 recorded there).** That ADR
sets one grammar for materials, controls, windows and accessibility settings; this one covers what makes Grassfield
recognisable and how it appears. The nine places where they meet have one owner each: the table "Coordination with
ADR-0039" below repeats ADR-0039's own, unchanged. ADR-0039 merged first, so this ADR is the one that follows it: its
D-Q4 (switches and slider fills on the selection fill, as macOS 27) and D-Q1 (sheet buttons measured on macOS 27) hold,
and IQ-B3 here changes the palette only, not which controls read it.

## Context

### The owner's brief (2026-10-29)
- One pull request per step towards main. Step 0: an audit and a proposal, no code, on the wallpapers (the shipped
  collection, the default, light and dark, videos; ADR-0016), the brand (logo, name, accent colour, the About screen,
  the icons of Grassfield's apps), and the lock screen with every transition: boot, login, logout, sleep, wake,
  restart, desktop loading. **Nothing may flicker or jump; everything appears once, in its place.**
- An "identity" ADR with concrete proposals (SVG or QML mockups, no Apple material) and the owner's questions, each with
  two or three options, their pros and cons, and a recommendation. Plus STATE.

### Rules this ADR works under
- **The Grassfield logo is the owner's mark, all rights reserved (decision of 2026-10-27).** Nothing here changes it:
  every mockup uses the path of `branding/icons/symbolic/grassfield-logo.svg` unchanged, and the proposals concern only
  where it appears and in which colour, which the owner decides (IQ-B1, IQ-B2). This ADR calls it "the Grassfield mark".
  **2026-10-30: the owner replaced the drawing** with a new mark of their own, an AI-assisted concept
  (`branding/concepts/grassfields-original-refined/`) redrawn as SVG in the proposed brand kit (`branding/brandkit-proposal/`,
  1342d2d9); its final adoption and legal clearance are the owner's, pending (`docs/legal/visual-review.md` E33). It now
  lives in two files on the 24 grid: `grassfield-logo-full.svg`, the full mark, unchanged, for 32 px and more (the brand
  kit, the website, future large About surfaces; no shell or app surface draws it today, and `tests/unit/tst_visualaudit.qml`
  keeps it loadable), and `grassfield-logo.svg`, its optical version for 16-24 px (the same blades over the same base, fewer
  and wider gaps), which every place listed under IQ-B1 draws at run time (14-25 px). The step 0 mockups show the old
  drawing (a grass tuft); they are dated design documents and were not redrawn.
  **2026-10-31: the owner replaced the drawing again** (« Je pars sur le B »): direction B, "Deux reliefs", of the v6
  directions drawn from four reference images the owner shared (`branding/concepts/grassfield-sommet-v6/`: a summit drawn
  as a band of constant width and a nearer relief as a filled shape, parted by one parallel channel; geometric, filled,
  no letter). The same two files carry it: `grassfield-logo-full.svg` is B's drawing (for 32 px and more) and
  `grassfield-logo.svg` its optical version for 16-24 px (the same slopes; measured perpendicular to them, the band from
  about 1.17 to 1.35 px and the channel from about 0.54 to 1.15 px at 16 px; the base on the 16 px pixel grid). The places, colours and rules of IQ-B1 do not change; the
  brand kit's symbol and lockups follow. Legal clearance of the new shape is the owner's, pending (`docs/legal/visual-review.md` E33).
- Every illustration is made here or under a compatible licence, documented in `docs/legal` (E39). No Apple asset and
  no Apple trademark name (master-prompt §14).
- The lock screen (`shell/security/lock`) and idle handling are security modules: only `WlSessionLock`,
  `PamContext("omarchy-lock-password")` and Quickshell's polkit; any change, even visual, needs an opus security review
  before merge, and every failure leaves the session locked (R12).
- Tokens only; real glass (ADR-0024).
- Areas under way in other branches are not touched and are planned after their merge: `shell/dock`, `shell/desktop`,
  `shell/menubar`, `ui/Grassfield/Ui/Appearance.qml`, `ui/Grassfield/Ui/Material.qml`, `apps/store`, `apps/files`,
  `apps/portal`, `apps/activity`, the Software Update pane.
- Where this container cannot render Grassfield, the text says **NOT VERIFIED**; the integrator makes the nested pass.

### What Grassfield has today (audit, short)
- **Wallpapers.** One procedural artwork, the same in both appearances, its colours outside the tokens (W-1 to W-3).
  Videos are the user's own (W-5). **At every login and shell restart the artwork shows first and the user's picture
  crossfades in over it, and the menu bar's text colour switches after login** (W-7, W-8). **The lock always shows the
  blurred artwork, never the user's wallpaper** (W-9).
- **Brand.** The mark appears in the menu bar, Settings > About, Search and as the default glyph of shell dialogs, never
  in the shell's About panel (B-3, B-9). The default accent is the Grassfield green but is called "Multicolour", next to
  a second, pickable green; Settings > About draws its Grassfield tile in that second green (B-7, B-8). Grassfield's own
  apps show the composed pack's icons in the session, except Store (B-10). No boot splash or login window of our own
  (B-11).
- **Lock.** Sound layout and contrast (L-1, L-2, L-5); hard cuts in and out, a black first frame, and an avatar and name
  that can change after the lock shows (L-3, L-4).
- **Transitions.** No ground colour and no single entrance: `#1C1C1E`, then the menu bar alone, then the artwork,
  then the picture (T-1 to T-8; since main 8b5efac, "startup-settle", the Dock and the desktop icons already wait until
  they are final and appear once, which removes T-7 and the Dock's part of T-3, T-4 and T-6); idle and display-off paths undim or light the desktop for a moment (T-10 to
  T-12); the lock clock can jump after a wake (T-14); a shell restart replays the whole start and, when locked, shows the
  compositor's red screen (T-15); the session ends with layers vanishing one by one (T-16).
- Storyboards of today and of the proposal: `mockups/t1-transitions.svg`.

## Decision (proposed)

### 1. Principles: everything appears once, in its place
- **P-1 One ground.** Before any Grassfield surface has drawn and after the last one is gone, the screen shows one
  colour, the *ground*: the mean colour of the wallpaper the session shows (the helper's sidecar already measures it,
  ADR-0016 §2; for an artwork it is a palette value). Hyprland's background colour, the wallpaper window's own colour,
  the lock surface's colour (under its scrim) and the exit cover all take it (ID-2).
- **P-2 The first frame is the final frame.** A surface is shown only with its final content: the settings read, the
  wallpaper's prepared still decoded, the bar tone known, the Dock's items and the icons' positions loaded. Nothing
  shows a default and then corrects itself (ID-3 to ID-6).
- **P-3 One entrance.** At session start the wallpaper comes first, out of the ground; then the menu bar, the Dock and
  the desktop icons appear together, once (ID-20). Nothing slides away right after appearing.
- **P-4 Continuity across the lock.** The lock shows the desktop's own picture. Windows go at once (the protocol leaves
  no choice), the picture stays, the scrim and text fade in; on unlock they fade out while the session is still locked,
  then it is released (IQ-T2, IQ-W4).
- **P-5 Security first.** No animation delays the lock: it is engaged at once and its fade happens inside the lock
  surface. The unlock fade happens before the release, and a failure during it leaves the session locked. Displays and
  sleep never wait for an animation.
- **P-6 Bounded waits.** Every "wait until ready" has a token-bounded timeout after which the surface shows what it has;
  a missing helper, a broken file or a slow disk never leaves the session blank.
- **P-7 Reduce Motion** turns every fade here into a cut or a crossfade of at most `motion.reducedMax`; the order rules
  still hold.
- **P-8 Measured.** Each surface logs once when it is shown; a nested test fails on a second showing, a wallpaper that
  changes kind at start, or a bar tone that changes at start (section 7).

### 2. Wallpapers
- **Collection (IQ-W2, owner: C, artworks and photographs).** Four Grassfield-made procedural artworks, each with a
  light and a dark variant: **Grassfield** (the hills of today), **Meadow** (grass blades close up, not the mark's
  shape), **Field Rows** (a field seen from above), **Ridgeline** (one quiet hill line, the calmest backdrop for glass);
  the eight colours of today; and **photographs** under the integrator's conditions (below). The artworks are drawn by
  one shared QML component from token palettes (ID-1), crisp at any size, with the menu bar tone known from the
  palette, never measured late. Mockup: `mockups/w2-collection.svg`.
- **Photographs (IQ-W2 C; the integrator's conditions, 2026-10-29).**
  - Each photograph is CC0 or CC BY, or commissioned with a written licence, and has its own provenance and licence
    entry in `docs/legal` (source, author, licence, date, changes made); its credit shows in About This Wallpaper.
  - None may resemble a well-known OS wallpaper (the side-by-side check of E32 covers them).
  - The list (a thumbnail, the source and the licence of each) goes to the owner for the legal call before any file
    ships.
  - The pull request states the total package weight. They install under `/usr/share/grassfield/wallpapers/` and go
    through the helper like any picture (ADR-0016: the shell decodes only the helper's output).
  - **Step 2c as built** (after the owner's call of 2026-10-31, "Owner decisions", and the owner's « Au build » for where
    the files live): `packaging/arch/wallpaper-photos.json` is the one list (names in English and French, author, credit,
    licence, Commons page, original, SHA-1); the PKGBUILD downloads the originals from `upload.wikimedia.org` (the ids
    and addresses in `wallpaper-pins.sh`), checks each by the SHA-1 Commons publishes, shrinks them with the build-only
    `grassfield-wallpaper-shrink` (at most 5120 px wide, JPEG quality 90, the EXIF orientation applied, no metadata kept;
    the installed helper still writes only into its cache) and installs them with `photos.json` under
    `/usr/share/grassfield/wallpapers/photos/` in a split package, `grassfield-wallpapers`, which `grassfield-desktop`
    depends on, as it does on the icon theme (so it is downloaded again with each release, like the icons). Settings >
    Wallpaper lists them in a Photographs section after the Grassfield artwork (`WallpaperConfig.parsePhotos`; an entry of
    the wrong shape is left out, an id is a plain file name); one is chosen as a picture (source `file`, through the
    helper like any other) and About This Wallpaper credits it as its licence asks (its own title, the author's credit line
    with its copyright notice, the source, the licence, Grassfield's changes: the integrator's review of e067f26f). The
    desktop's own About This
    Wallpaper card shows them too (2026-11-01, the owner's « Maintenant dans la #79 »: `WallpaperState` reads the list
    as Settings does, `WallpaperConfig.aboutEntryOf` picks the online picture's or the shown photograph's attribution,
    `tst_wallpaper.qml` +2). Legal: E40 and `THIRD_PARTY.md` "5c";
    `tests/ci/wallpaper_photos.py` holds the list, the pins, the PKGBUILD and the legal texts together. The package weight:
    estimated at about 70 MB from the 960 px thumbnails at the same quality (the originals could not be downloaded in the
    container that built it); the build gives the real figure. `scripts/dev/photos.sh` prepares them under `.dev/photos`
    for a dev session.
- **Default (IQ-W1, owner: C, the time of day).** The Grassfield hills through the day: **Dawn**, **Day**, **Evening**
  and **Night**, like macOS's dynamic desktop. Light and dark still choose the variant set: four light palettes in the
  light appearance, four dark ones in the dark appearance (the same scenes, darker; the dark Evening is today's
  artwork), so the dark desktop never shows the bright Day. Mockup: `mockups/w1-default-wallpaper.svg` (option C strip;
  its Day and Night panels are the light Day and the dark Night).
- **The time-of-day rule (the integrator's condition: the exact rule before building it).**
  - **Times from the time zone only.** No location service, no network. The zone is the system's (`timedatectl`'s
    zone, which is the target of `/etc/localtime` under the zoneinfo directory). Its reference point, in this order
    (review of 6c310a8: zones tzdata now treats as aliases, the owner's Europe/Amsterdam among them, have no row in
    `zone1970.tab`):
    1. its row in tzdata's `zone1970.tab` (the coordinates of the zone's principal city);
    2. its row in `zone.tab`, which keeps one for those aliases (Europe/Amsterdam, Africa/Douala, Europe/Stockholm,
       Europe/Oslo, Europe/Copenhagen, Arctic/Longyearbyen, ...);
    3. the zone it links to (`tzdata.zi` "L" lines), looked up in 1 and 2;
    4. none: the fixed hours.
    Sunrise and sunset for the local date come from the NOAA approximation (solar zenith 90.833°).
  - **Probe** `docs/audits/identity-2026-10-29/timeofday-probe.py` (12 checks, exit 1 on a failure): Europe/Paris on
    2026-10-29 07:31 and 17:37 CET and on 2026-06-21 05:46 and 21:57 CEST; America/New_York on 2026-10-29 07:21 and
    17:57 EDT; Europe/Amsterdam on 2026-12-21 08:47 and 16:28 CET from `zone.tab` (the review's own figures); Africa/Douala
    and Europe/Stockholm from `zone.tab`; America/Montreal through its link to America/Toronto; Arctic/Longyearbyen
    in polar night and polar day (the fixed hours); UTC (no point); and two explicit points for the short-day and
    short-night rules. With `zone1970.tab` alone (the first rule's behaviour: no `zone.tab`, no links) six checks fail,
    Amsterdam and Montreal among them (re-checked for step 1b with a scratch zoneinfo directory holding that file only). An
    independent formula agrees within 3 minutes (the integrator's check); agreement with published times is NOT
    VERIFIED (no network here).
  - **Phases.** Dawn from 30 min before sunrise; Day from 90 min after sunrise; Evening from 90 min before sunset; Night
    from 30 min after sunset (tokens `wallpaper.phase*`). A day shorter than 3 h has no Day (Dawn runs to the middle of
    the daylight, then Evening); a night shorter than 1 h has no Night.
  - **Fixed hours** where the zone gives no point after the four lookups (UTC, `Etc/*`) or the sun neither rises nor
    sets that day (polar day or night): Dawn 06:00, Day 08:00, Evening 18:00, Night 20:30, local time.
  - **Changes.** A slow crossfade through the two-slot model (`wallpaper.phaseFadeMs`, 20 s; Reduce Motion: a cut),
    never during a pointer drag or while a full-screen window is on that output: deferred to the first moment neither
    holds.
  - **Scheduling.** One timer to the next boundary; recomputed at shell start, after a resume, at a time-zone change and
    at local midnight. No polling.
  - **Gate A2.** The bar's tone follows the wallpaper, so the band must hold 4.5:1 at every phase: the token test
    computes the chosen tone (and the band where it is needed) over the strip at t = 0, 0.25, 0.5, 0.75 and 1 of each
    of the eight transitions (four per set). ADR-0039 owns the role table; these are this ADR's roles.
  - **Choice in Settings.** The Grassfield tile offers "Time of Day" (the default), "Automatic" (Day in the light
    appearance, Evening in the dark one), "Light" (Day) and "Dark" (Evening). The other three artworks follow the
    appearance only.
- **Following the appearance.** A switch of appearance crossfades between the two variant sets through the existing
  two-slot model (one fixed `wallpaper.crossfadeMs`), the bar tone switching at the crossfade's midpoint from the
  palette; Reduce Motion cuts (ID-14). Settings shows each artwork as one tile in the current appearance, with
  "Automatic / Light / Dark" for the chosen one (macOS's pop-up for its dynamic wallpapers, ASSUMPTION). Settings >
  Appearance draws the real dark variant instead of darkening the art (W-3). The lock also draws the artwork
  (`LockView.qml:80`): `WallpaperArt` without a parameter keeps today's drawing, so step 2 edits nothing in
  `shell/security` and the lock's output stays as it is until step 4a changes it under the security review (reviews of
  b44d17e and ed21d46).
- **Step 2 as built** (in the one pull request of 2026-10-31):
  - **Palettes as tokens (ID-1).** 44 `artwork.*` tokens: the Grassfield hills at Dawn, Day, Evening and Night in a light and a
    dark set (sky, sun, its place, four hills), Meadow, Field Rows and Ridgeline light and dark. The light Dawn, Day and Night
    are the mockups'; the light Evening is new (a warm dusk); the dark Dawn, Day and Night are the light ones darkened in
    OKLCH (lightness x0.52 to x0.80, chroma x0.85 for the sky and x0.72 for the hills), so every dark phase keeps light menu
    bar text; the dark Evening is the artwork as it was. The written exception of `GrassfieldArtwork.qml` is gone
    (`tests/ci/qml_literals.py` no longer allows it a colour).
  - **One component.** `GrassfieldArtwork.qml` draws the four artworks from those palettes (`artwork`, `variant`; the seeded
    geometry of Meadow and Field Rows and the night's stars in the private `Artwork.js`), clipped to its own rectangle.
    Without parameters it draws the dark Evening. The sun is now a real radial glow (a `Shape`: the `RadialGradient` of a
    `Rectangle` drew a hard disc), which the lock and the screen saver show too; the lock's own picture changes under step 4a.
  - **The time of day.** `TimeOfDay.js` (public in `Grassfield.Ui`) is the probe's rule in JavaScript: the zone's point from
    `zone1970.tab`, `zone.tab` and the links of `tzdata.zi`, the NOAA sunrise and sunset, the phases, the short-day and
    short-night rules, the fixed hours (`wallpaper.phase*` tokens). Its tests (`tst_timeofday.qml`) are the probe's twelve
    checks on fixtures cut from tzdata 2026e. The shell's `DayPhase` service reads the zone (TZ, else the target of
    `/etc/localtime`) and the three tables once, then keeps one timer to the next change, recomputed when the clock jumps
    (a wake, a clock change), at local midnight and with the zone read again when the UTC offset moves.
  - **Settings.** `wallpaper.artwork` and `wallpaper.artworkVariant` (schema, defaults, contract, `WallpaperConfig`;
    additive). Settings > Wallpaper's Grassfield section shows the four artworks, each tile in the current appearance; the
    current wallpaper's group gets the choice of variant (Time of Day, for the Grassfield artwork only, Automatic, Light,
    Dark; `WallpaperConfig.artworkVariantFor`); the preview draws the variant the desktop shows (the shell publishes the
    phase in its wallpaper status). Settings > Appearance draws the dark variant instead of darkening the light one (W-3).
  - **The desktop.** Each output resolves the variant from the choice, the appearance and the phase. A new phase crossfades
    over `wallpaper.phaseFadeMs` (20 s) and waits while a full-screen window is on that output; a new appearance crossfades
    over `wallpaper.crossfadeMs` with the bar's tone switching at the midpoint (ID-14); Reduce Motion cuts; an output's
    first wallpaper and the first phase known at start cut in (no fade from the default artwork). The bar's tone, the glass
    backdrop and the window's colour read the palette on screen (they read slot A's before).
  - **Gate A2.** `test_contrast_tokens.py` checks every palette's tone over the strip under the bar, without the band, on
    displays 720 to 2160 pixels tall (6.9:1 or more). During a crossfade between two artworks the tone in effect is checked
    at every twentieth of the fade (`BarToneLogic.artFadeNeedsBand`); where it would fall under 4.5:1 the band is on for the
    fade and only then: Dawn to Day in the light set and an appearance switch at Day (`tst_bartone.qml`).
  - **Not done here.** A pointer drag does not hold a phase change back: the shell has no signal for a drag in progress
    (Hyprland 0.56 gives none); only a full-screen window does. NOT VERIFIED: the artworks and the fades on screen (nested:
    `qs ipc call wallpaper phase dawn`, and the Settings tiles), and the zone files on the owner's machine.
- **Videos (IQ-W3, owner: A, the drawn animation in 1.0).** No video file ships; the user's own videos stay as built
  (ADR-0016 W7). The default artwork gets a **moving** variant drawn live (clouds drift, the light changes slowly), also
  a screen saver kind (in `shell/saver`; nothing in `shell/security`, review of 6c310a8). The integrator's conditions
  (2026-10-29): off by default; it pauses like a video, when hidden,
  in Low Power Mode or on battery, under a full-screen app, while locked (and when idle, with Reduce Motion and in the
  Reduced profile, as the video policy already does); P1 and P3 are measured with it on before its pull request asks
  for a merge, and a cost over budget blocks it.
- **Step 9 as built** (2026-10-31, in the one pull request; nothing in `shell/security`): `wallpaper.moving` (schema,
  defaults, contract, `WallpaperConfig`; off by default) and the screen saver kind `moving` ("Clouds"). The Grassfield
  artwork (`GrassfieldArtwork.qml`) draws four seeded clouds (`Artwork.clouds`: between 0.1 and 0.5 of the height, so
  nothing enters the strip under the menu bar and the bar's tone and gate A2 stay those of the still picture; under the
  hills) that drift across the sky (`wallpaper.movingCloudMs` 240 s for a cloud of speed 1) and a glow that softens by
  `wallpaper.movingLightDepth` over `wallpaper.movingLightMs` (90 s); colours `artwork.cloudLight` and `cloudDark` at
  `wallpaper.movingCloudOpacityLight` 0.5 and `Dark` 0.14. It advances by `wallpaper.movingFrameMs` (100 ms) steps of a
  Timer, never every frame, only while `playing`; paused, it holds where it is. The desktop gives each slot the video's
  pause policy (`WallpaperConfig.playbackState`: locked, full screen, Reduce Motion, the Reduced profile, on battery unless
  "Play on battery power", idle), only while the slot is on screen; the idle monitor runs for it too. The screen saver's
  kind plays while the saver is shown, still with Reduce Motion. Settings > Wallpaper shows "Moving clouds" under the
  Grassfield artwork; Settings > Screen Saver adds "Clouds". Tests: `tst_artwork.qml` (the clouds' bounds and seeding,
  the light, it moves only while playing), `tst_wallpaper.qml`, `tst_settingswallpaper.qml`, `tst_savermodel.qml`,
  `tst_settingsscreensaver.qml`; an offscreen render of the four phases with clouds. **The integrator's condition is not
  met in this container:** P1 and P3 with the moving variant on are NOT MEASURED (no nested session, no reference
  machine), so the merge waits for that measurement, and a cost over budget blocks the variant (it stays off by default
  meanwhile).
- **Step 9 as revised** (2026-11-01, the integrator's review of e067f26f): P1 measured over budget with the clouds moving
  on the desktop (nested proxy, session unlocked, 300 s each: 3.70 % of one core with them, 0.64 % without, budget
  0.77 %). The integrator's decision, closest to macOS's moving wallpapers: **the motion plays on the lock screen and
  slows to a still as the desktop appears; the desktop picture is still.** As built:
  - Desktop: no `WallpaperSlot` plays the artwork any more and the idle monitor is a video's only; each slot draws the
    clouds where the last lock left them (`WallpaperState.motionOf`, per output, kept for the session, 0 at start).
  - Lock screen (`shell/security`, display only; opus security review): `LockView` takes `wallpaper.moving` and that
    position once at creation (through `LockStills` and `Lock.qml`); the artwork's own Timer moves them while the backdrop
    is the artwork, not while releasing, not under Reduce Motion, not while Idle has the displays off (`Lock.displaysOff`,
    set from Idle's `displayOff`) and not once unlocked (`LockView.motionHeld`; the start position is taken until they
    first move). Opus security review of bdc11b2d: **PASS**; its two MINORs (the tests' patterns, three mutants) and three
    NITs are fixed in 7db57a7d, each mutant now killed. Counter-review of 7db57a7d and de14f4c1: **PASS**; its MINOR (no
    handler could be added unnoticed: the view's and its instance's handlers are pinned, three mutants) and its NIT (the
    start taken a turn after the clouds first play) are fixed after it. When the release fade starts they slow down
    linearly to a stop within it
    (`Easing.OutQuad` over the controller's `releaseMs`; `WallpaperConfig.lockMotionRest`), and `Lock.qml` gives that frame
    to the desktop at once (`restMotion`, in a `try`), so the desktop under the lock is the frame the lock rests on. The
    release never waits for it, and the lock path (`lock`, `engage`, `release`, `restore`) reads none of it.
  - Settings > Wallpaper's footnote says so. Tests: `tst_wallpaper.qml` (`motionIn`, `withMotion`, `lockMotionRest`, the
    desktop draws them still), `tst_lockbackdrop.qml` (`test_theCloudsMoveOnTheLockOnly`), each guard checked by a mutant.
  - **NOT MEASURED here** (no nested session): P1 with `wallpaper.moving` on (the desktop now renders nothing for it) and
    P3, for the integrator's re-measure. On the lock screen the clouds cost what they cost on the desktop before, while the
    lock shows with the displays on.
- **First frame (ID-3).** The wallpaper window shows the **last applied wallpaper's prepared still** from the cache as
  its first frame, with the bar tone from its stored statistics, and maps only then (bounded by
  `wallpaper.firstShowTimeoutMs`, after which the artwork). When the feed's result is the same file, nothing fades.
  This removes the artwork-then-picture sequence (W-7) and the late tone switch (W-8), and keeps ADR-0016's rule that
  the shell decodes only the helper's own output.
- **Step 3 as built** (in the one pull request of 2026-10-31; nothing in `shell/security`):
  - **First frame (ID-3).** Each output's wallpaper window maps only with its first frame (`visible: win.firstReady`).
    What each output shows is recorded in `wallpaper.json` once it is on screen (`shown`, per output: a picture with its
    prepared file, strip and whole-picture statistics and mean colour, or a video's poster marked as one; the artwork and
    variant; a colour; each with the artwork and variant the output would draw instead, the lock's fallback; ADR-0020 row),
    and at the next start `WallpaperConfig.stillOf` reads a picture back only when it is one of the helper's own (a 32-hex
    cache name directly in the prepared folder: the shell still decodes nothing else). The first frame is chosen by
    `WallpaperConfig.firstFrameChoice`: nothing before `wallpaper.json` was read; then the stored still until the feed's
    first result, which decides (it carries the phase and the appearance: a phase or an appearance known before it changes
    nothing, review of 4457edc1). The still goes into slot A with the bar tone of its stored strip, and the window maps once
    it is decoded; the artwork and a colour map at once; when the feed's result is the still's file nothing changes but its
    statistics (the helper's, fresh). A still that cannot be decoded, or nothing within `wallpaper.firstShowTimeoutMs`
    (1500 ms), gives the artwork. A video has no still for the desktop (its poster lives in the video cache): it waits for
    the feed within the same bound. The bar's tone is never reported from the default artwork before the first frame.
  - **Ground (ID-2).** `Artwork.ground` (the sRGB mean of the sky's middle and the middle of the land, in whole channel
    values) gives each palette a ground; the default artwork's, `#2F6D5F`, is now `session.ground` and `looknfeel.lua`'s
    `background_color` (`tst_artwork.qml` and `tst_sessionexit.qml` hold the three equal). `WallpaperConfig.groundOf` gives
    the ground of what an output shows (a picture's mean colour from the helper, a colour, the artwork's), reported to the
    `Ground` service when it is on screen. The wallpaper window's own colour is its output's ground, and `Compositor.qml`
    sets Hyprland's `misc.background_color` to the first screen's (`Ground.current`) through the request socket like the
    blur (`Minimized.groundCall`): once the first screen has reported (`Ground.known`: at a shell restart the compositor
    keeps the previous run's ground until then, no flash to the default), on each change (debounced), after a config
    reload; an error answer stops the pushes until the next change and the static default stays. The exit cover fades to
    the colour Hyprland last answered "ok" to (`Ground.accepted`, the static default before), which is what shows once the
    shell has stopped. VERIFY on 0.56.2 (section "Not verified"): that the call is accepted at run time and repaints the
    background.
  - **No compositor fade (ID-4).** `gf-wallpaper-no-anim` in `windows.lua`.
  - **Hotplug (ID-15, the wallpaper's part).** A new output's window takes the same path: unmapped (the compositor's
    ground shows) until its still or its feed's first result, then mapped once; `Ground.of` gives an output without a
    report the compositor's ground.
  - **Measurement (ID-16).** `Journal` starts its clock with the desktop (`grassfield-shell: journal starts`) and logs
    `grassfield-shell: shown wallpaper <output> <ms>` when a window maps and `hidden` when a mapped one goes, plus `grassfield-shell: wallpaper first <kind> [<artwork> <variant>] source=<source>
    output=<output>`; `tests/visual/appear-once.sh` comes with step 6, which adds the bars' lines.
  - Tests: `tst_wallpaper.qml` (`stillOf` refuses any file but a cache name in the prepared folder, `withShown`,
    `firstFrameChoice`, `groundOf`, `groundFor`, `withCarousel` and `stateText` keep every part of `wallpaper.json`, the
    window's wiring from its source), `tst_artwork.qml` (every palette's ground, the default's equal to `session.ground`),
    `tst_minimized.qml` (`groundCall` interpolates only `#rrggbb`), `tst_sessionexit.qml` (the cover on `Ground.accepted`,
    the compositor's push only once known). Review of 4457edc1 (FAIL: M1 the phase or appearance before the feed; m1 the
    flash at a restart; m2 the cover's colour; m3 the journal's clock; m4 the write path untested; two NITs): all fixed;
    the counter-review of c5d43be4 found M1's second half (a still already mapped was cut to the placeholder artwork by a
    phase or appearance event before the feed's first result): the phase, appearance and full-screen handlers act only once
    the feed has given its first result.
    NOT VERIFIED (nested): the first frame at start and at a shell restart, the hotplug, the background colour after a
    change and a reload.
- **Step 4a as built** (2026-10-31, in the one pull request; `shell/security`, so under the opus security review):
  - **The data.** The desktop's record of what each output shows (`wallpaper.json` `shown`, step 3) is what the lock draws:
    `WallpaperState.lockBackdrop` (`WallpaperConfig.lockBackdropOf`) gives a picture only as a plain cache name in the
    prepared or the video folder (the video's poster), else the colour, else the artwork and variant (also every picture's
    fallback). Read from that record rather than from the desktop's live objects; at ADR-0041 S2 the security process needs
    its own watched reader of `shown` (WallpaperState reads the file once and is a desktop store with side effects), with
    the pure `lockBackdropOf` (noted in ADR-0041 S2).
  - **Ready before it is needed (ID-7).** `shell/security/lock/LockStill.qml`, one per output in `LockStills.qml` (which
    `Lock.qml` creates at run time, last in its `Component.onCompleted`, never as a declared child: a display file that fails
    to load costs the surfaces their backdrop and picture, never the lock), decides the backdrop while the session is
    unlocked, when the wallpaper changes: a picture is checked again (`/usr/bin/realpath -m` with the two cache folders: the
    file's real path a plain cache name directly in one of their real paths, `WallpaperConfig.lockStillReal`;
    `/usr/bin/stat --printf %f|%s`: the raw mode, which no locale translates, a regular file of at most
    `wallpaper.lockStillMaxBytes`, `lockStillStatOk`; absolute paths, argument vectors, one process per step and request, a
    superseded answer dropped) and decoded by a hidden `Image` into Qt's pixmap cache (no `sourceSize`: the helper wrote it at the output's
    physical size, and a `sourceSize` would key the cache on each window's scale). The account picture is decoded the same
    way (`avatarPreload`, the shell's PNG copy of at most 256 x 256). A lock surface takes its backdrop when created, or
    when first decided (a hotplugged output, a wallpaper changed just before), at most `wallpaper.firstShowTimeoutMs` later,
    then the artwork; the name and the picture at creation (the picture only if already decoded, else the initials); then
    nothing changes but the clock, which `SleepInhibitor.afterResume` refreshes (`Lock.resumed`). Engaging, releasing and
    restoring the lock read none of it (`tst_lockbackdrop.qml`).
  - **Ground (ID-2, ID-15).** The lock surface's own colour is its output's ground (`Ground.of`): what shows before the
    content and while the backdrop is undecided, under the scrim and the text, which are there at once.
  - **Sharp, banded scrim (IQ-W4 A).** No blur any more (`lock.blurMax` removed); the scrim is `lock.dimOpacity` from the
    top to the bottom of the date and clock and from the top of the account column to the bottom, `lock.scrimClearOpacity`
    0.25 between them, `lock.scrimFeather` 48 px ramps on the clear side, bound to the two columns' geometry so every text
    line lies on 0.6 at every text scale; without room for a clear band the whole surface stays at 0.6. A2: the text roles
    are unchanged (`contrast-roles.json`, `test_contrast_tokens.py` reads the scrim's lines and the columns).
  - **Opus security review of cbd6ef05: FAIL, no BLOCKER** (fail closed intact; the reviewer confirmed on Qt 6.10 that the
    committed `LockView.qml` loads, that its still is Ready synchronously from the windowless preload, and that the field
    has focus). MAJOR 1 `tst_lockbackdrop.qml` failed under `scripts/dev/test.sh` (no `QML_XHR_ALLOW_FILE_READ` for
    `tests/security`) → set there. MAJOR 2 `stat %F` is translated by the locale (the artwork always on a French session) →
    `%f`, the raw mode. MAJOR 3 no evidence that `Lock.qml` with a `Variants` and an `Image` still loads in Quickshell → the
    display data moved to `LockStills.qml`, created at run time and caught; what is left in `Lock.qml` is one function. Still
    required before the merge (NOT VERIFIED here, no Quickshell): `tests/security/lock_monitor_model.sh`, `dev_gate.sh`,
    `reload_locked.sh`, nested L1 to L5. MINOR 1 (the decoded file can differ from the checked one, for a process of the
    same user writing the 0700 cache): Qt's `@2x` lookup is off for the shell (`QT_HIGHDPI_DISABLE_2X_IMAGE_LOADING=1` in
    `grassfield-shell.service`); the rename race and the format sniffing (every installed image plugin reachable) are
    bounded (64 MiB, Qt's 256 MiB allocation limit, `wallpaper.toolTimeoutMs`) and go to S2 (only the JPEG plugin, a file
    the process opened itself). MINOR 2 S2's reader (above, ADR-0041). MINOR 3 tests shallow → the pure checks are tested
    (`tst_wallpaper.qml` `test_lockStillChecks`), and an offscreen probe with stand-in Quickshell types (simulated
    processes, a real PNG) showed: nothing shown, undecided; a picture checked and decoded; a colour at once; a directory,
    a path outside the cache and a missing file, the artwork. NITs: focus first in `LockView`, the surface colour taken
    once, a failed check clears the image, the folders canonicalized.
  - Tests: `tests/security/tst_lockbackdrop.qml` (the checks, the same pixmap options on both sides, taken once, the
    clock on resume, the ground, nothing on the lock path, the display data created at run time; four planted mutants each
    fail it), `tst_wallpaper.qml`
    (`lockBackdropOf`), `test_contrast_tokens.py`, `lock_surfaces.sh` (the clock's one refresh, and a mutant). An offscreen
    render of the real `LockView.qml` with stand-in modules (white and the light Day artwork, 1280 x 800; text layers off,
    since offscreen Qt draws no `MultiEffect`) shows every text line on the dark bands; it also caught `top` and `bottom`,
    FINAL properties of `Item` in Qt 6, which would have kept `LockView` from loading. NOT VERIFIED (nested): the still in
    the lock's first frame (the pixmap cache hit with `asynchronous: true`), a hotplugged output while locked, the clock
    after a real sleep, the A2 lock run over the new backdrops (`tests/visual/contrast.sh --surfaces lock`), L1 to L5.
- **Step 4b as built** (2026-10-31; `shell/security`, under the opus security review): the machine gains `releasing`
  (`LockMachine.js`): a PAM success (`success` while authenticating, `fingerprint` while locked or authenticating) enters
  it, `released` leaves it for `unlocked` and is the only way there; `request`, `error`, `timeout`, `abort` bring it back
  to `locked`, `lost` to `locking`; it counts as holding. `LockController` arms a Timer of `releaseMs`
  (`Appearance.duration(lock.fadeOutMs)`, 200) at the PAM success and emits `unlockRequested` only when it ends;
  `interruptRelease()` (called first by every `Lock.lock`, so an idle, sleep, lid or IPC request during the fade keeps the
  lock) stops it and the success is spent. `LockView` fades the scrim, the date and clock and the account column in over
  `lock.fadeInMs` (200) once the surface shows and out while releasing; the wallpaper does not fade; the field takes input
  from the first frame and none while releasing. Tests: `tst_lockmachine.qml` (+1, the exhaustive check now covers
  `releasing` and every two-event path), `tst_lockcontroller.qml` (+4: the release after the fade, a lock request during
  it, a lost lock during it, the fingerprint), `tst_lockbackdrop.qml` (+1: the wiring); planted mutants (success straight
  to unlocked, an always synchronous release, an error during the fade not relocking) each fail them. The fade-in from
  the idle dim's level (ID-8) is step 5. NOT VERIFIED (nested, required before the merge): L1 to L5 with the fades,
  `reload_locked.sh` (a soft reload during `releasing` must keep the lock: `persist.intent` stays true until `release()`).
- **Step 5 as built** (2026-10-31; `shell/security`, under the opus security review): ID-8 (the dim stays until the lock it
  led to holds, bounded; the lock's content starts at the dim's level; the saver on screen stays until the lock holds,
  bounded), IQ-T4 A (`lock.requirePasswordAfterDisplayOff`, schema, contract, Settings > Lock Screen with its footnotes and
  French strings; a display that turns off for inactivity locks at once, the displays on until the lock holds, or after
  the delay, or never; `lock.idleMinutes` the ceiling), IQ-T5 A (`misc.lockdead_screen_delay = 5000`). With it, the opus
  review of step 4b (PASS): its MINOR (a lock request now also abandons a password check in flight) and its NITs (the fade
  starts right after the focus; the dev hook docs name `releasing`). Tests: `tst_idlemodel.qml` (+1),
  `tst_lockcontroller.qml` (+1), `tst_lockbackdrop.qml` (+1: the order's wiring and the delay's bounds),
  `tst_settingslock.qml` (+1, the footnotes), `test_contrast_tokens.py` (the carried dim declared). NOT VERIFIED (nested,
  before the merge): the order on screen, the display-off lock on a real display, only black during the lockdead delay.
- **Lock still.** ADR-0016 §6 (W8) as already specified, plus the preloaded still of ID-7 (section 4).
- **Legibility (A2).** Every variant goes through `tests/visual/contrast.sh` (menu bar strip, desktop labels, lock);
  the artworks' tones come from their palettes.

### 3. Brand
- **The mark (IQ-B1, owner: B, few places, green; the file is not touched).** Where it appears, in what colour, and the rules of its
  use (clear space, smallest size, what is never done to it) are the owner's to set, so all three are in IQ-B1 (review
  of b44d17e). Places under B: the menu bar's system button (monochrome, the bar's text colour), About This Computer and
  Settings > General > About (the Grassfield green), Software Update's Grassfield release row (the brand green, as About's,
  since 9903e56d), the Search result for About; shell dialogs show their subject's symbol instead of the mark. Only the file's path is used, at run time. Mockup: `mockups/b1-logo-use.svg`.
  The owner replaced the drawing on 2026-10-30 and again on 2026-10-31 (see "Rules this ADR works under"); the places and colours stay as listed,
  and the places above draw `grassfield-logo.svg`, its optical version (menu bar 16 px, About This Computer's product line 14,
  Settings rows 15, Search 25), and `grassfield-logo-full.svg` (the full mark, 32 px and more) has no surface under B (a
  48 px full mark in the dialogs was reverted for that reason, 1bdd69e3).
  Step 1d as built: the shell dialogs show their subject's symbol. `Popups.notice(title, message, symbol)` names it (Sleep's
  dev notice the moon, Restart's and Shut Down's the power symbol, an app already quit the Force Quit cross, a document
  that cannot be opened the document); a notice without one shows the information symbol (`PopupKinds.noticeSymbol`: a
  missing symbol through a string-typed parameter arrived as "undefined" and drew an empty frame, the review of 52b2bec),
  and so does a confirmation whose action has no symbol; neither dialog draws the mark. `tests/ci/mark_places.py` (logic
  layer) holds the places: the menu bar, About This Computer, General > About, Software Update's Grassfield row and Search
  draw the mark, in any string that names it, a file path included; nothing else does; every notice names a symbol that
  `ui/Grassfield/Ui/icons` holds.
- **The name (ID-12, IQ-B2).** "Grassfield" names the product in running UI ("Grassfield menu", "Grassfield
  Settings"); "Grassfield Desktop" where the product and its version are stated (About, the session's comment);
  "Grassfield OS" only from M6 (§14). App names keep the owner's decisions (L1, ADR-0038 AQ1). The greeter's "Grassfield
  (uwsm)" suffix stays (Omarchy's theme needs it to pick the session, B-6), a documented limit. No lockup or wordmark
  (IQ-B2, owner: A, "no logotype"); the mark alone is the symbol.
- **The accent (IQ-B3, owner: A, "Grassfield").** The default is named "Grassfield" (a green swatch first in the row, in place
  of the Multicolour wheel), the pickable Green moves to a value clearly apart from the brand green with its own 4.5:1
  text, and the brand green is the existing default-accent tokens (`color.light.accent`, `#26763F` until the owner's
  choice of 2026-10-30 made it the deeper `#195E3F`, white text 7.7:1; `color.dark.accent` `#4FB36B`; no new brand
  token). Settings > About's tile uses it (ID-11). The pickable Green also colours Settings
  tiles (the sidebar's Battery and Motion, `apps/settings/qml/Main.qml:27, 32`; rows of Accessibility, Menu Bar, Software
  Update and Storage): moving it moves them (review of b44d17e). Mockup: `mockups/b2-accent.svg`.
  Step 1c as built: Settings > Appearance's first swatch is "Grassfield", one disc of the brand green (the colour wheel is
  gone); the stored value stays `multicolor` (no grassfield.json to migrate). The pickable Green is `#6DB53C` with dark
  text `#10240A` (6.5:1) in the light appearance, the owner's choice B of 2026-10-30 (below): OKLab distance 0.21 from the
  brand green `#26763F` and 0.29 from the deeper `#195E3F` of 2026-10-30, where `#3A7512` was 0.04; the dark appearance keeps `#8BD34E` (0.12 already). Like yellow it holds dark
  text, so its dark-appearance selection pair is its light pair (`color.selectionDark.green`, the rule that a selection
  is never darker than the light accent), its focus ring falls back to the text colour on light grounds
  (`Accent.focusRing`), its thin marks in the GTK themes are pinned at 2.32:1 and 2.46:1 (2.48:1 before the warm neutrals; `tests/ci/gtk_themes.py`), and
  the white glyphs of the Settings tiles drawn in it are 2.5:1, as macOS draws them. General > About's Grassfield row
  draws its tile in the brand green (`SettingsRow` `tileColor: "grassfield"`, ID-11), and so does Software Update's
  Grassfield release row. Text and glyphs drawn in the accent colour read `colors.accentInk`: in the light appearance a
  light accent's darker shade (`color.accentInkLight`: yellow and green since the amendment 2026-11-03 below, 4.5:1 on an app window; macOS draws a light
  accent's text darker), the accent itself elsewhere (the integrator's review of 5391761, below).
- **About This Computer (ID-19, the macOS model; review of b44d17e).** Computer first, as macOS 27 and as Settings >
  About already do: the
  Grassfield-drawn picture of the computer (`DevicePicture`, by chassis), its model name, processor, memory, graphics,
  then "Grassfield Desktop 1.0" with the mark in the brand green, "More Info…" (opens Settings > General > About) and
  "Built for Omarchy · based on Arch Linux" (§14 wording). Mockup: `mockups/b3-about.svg`. Its form (step 1b, chosen on
  2026-10-29 when the step started, « Fenêtre de Réglages », the recommended option): Settings' own small window,
  `grassfield-settings --about` (`apps/settings/qml/AboutWindow.qml`), of fixed size, in the titlebar-only style (role
  "info"), mapped once hostname1 and lspci have answered (asynchronously: nothing waits on the GUI thread), at the latest
  after `settings.aboutWindowRevealTimeout` (P-2, P-6). Settings becomes one instance per user (the review of ce69dc6,
  MINOR 3; chosen on 2026-10-29, « Instance unique ici », recommended; Activity Monitor's AM1 pattern, ADR-0038 AD34): the
  running Settings owns `org.grassfield.Settings` on the session bus, a second launch hands it `--section` or `--about`,
  so there is one About window and one Settings window, in one process; More Info… brings that Settings window to
  General > About, and the shell's Settings… and section links bring it to their page instead of opening a second one.
  The shell's sheet (`shell/overlay/AboutPanel.qml`) and its popup kind are retired. Weighed: the
  shell's own window or sheet (no window of its own in the Dock, the Overview and the switcher; macOS's About This Mac
  is a window).
- **App icons (IQ-B5, owner: C, own icons where the pack has none).** Grassfield's own icons where the pack has no system app
  of that role: Store, Activity Monitor and the Dock's Apps tile; Files, Settings and Preview keep the pack's drawings,
  as the owner ruled on 2026-10-23. The own icons follow one grammar: one tile (104 on the 128 grid, radius 23.4, which
  is ADR-0014's plate radius 0.225), a top-to-bottom gradient and a light inner rim, one drawing in the brand palette
  inside 72 % of the tile (so ADR-0014's Dark, Clear and Tinted plates take it), no text. Activity Monitor is a gauge on
  a light tile and the Apps tile three fanned cards, drawn away from macOS's own Activity Monitor (a dark screen with a
  green graph) and Apps (a grid of coloured squares) icons; whether they are far enough is the owner's legal call
  (E39), asked again with the drawings before step 8 ships them. Mockup: `mockups/b4-app-icons.svg`.
- **Step 8 as built** (2026-10-31, in the one pull request; nothing in `shell/security`): the owner's legal call on the
  two drawings, shown at 104 and 16 px in light and dark: « Livrer les deux » (legal E39). `branding/icons/apps/`
  `org.grassfield.Store.svg` (the bag set on the grammar: 104 tile, radius 23.4, the rim), `org.grassfield.Activity.svg`
  (the gauge) and `org.grassfield.Apps.svg` (the fanned cards, new; `grassfield-desktop` installs it in hicolor, so every
  icon theme finds it); the `org.grassfield.Apps` alias to the pack's app grid is gone from
  `packaging/arch/icons-aliases.txt` (the Store and Activity Monitor never had one); Files, Settings and Preview keep the
  pack. `branding/LICENSES.md` rows; `docs/specs/dock.md` item 19; ADR-0017's note; `scripts/dev/devenv.sh` puts the Apps
  tile's icon in the dev hicolor (review of ee7fe429: PASS, its MINOR and NITs taken but the versioned dependency on
  `grassfield-icons`, which would make every desktop update download the 60 MiB pack for a cosmetic case). NOT VERIFIED:
  the icons in the Dock, the Apps panel and the Store in a session, in the Dark, Clear and Tinted modes (nested);
  `makepkg`.
- **Boot and login (IQ-L1, owner: C, an SDDM theme and a Plymouth theme).** Grassfield's look from power-on: a
  login theme in the lock screen's layout for SDDM's own greeter, and a boot theme with the mark for the disk password.
  The integrator's conditions (2026-10-29):
  - its own ADR first, and an opus security review; SDDM's own PAM service, no PAM file; no change to Omarchy's Limine
    or disk-encryption flow beyond the theme. The ADR shows how R12 holds for both themes:
    - SDDM: a theme for SDDM's own greeter, not a greeter; master-prompt §4 allows "SDDM theming later";
    - **Plymouth is outside today's allowance** (review of 6c310a8): plymouthd runs as root inside the boot image and
      draws the disk-password prompt, and master-prompt §4 allows SDDM theming only. The L1 ADR needs the owner's
      explicit go-ahead for Plymouth, inside that ADR, before any Plymouth work;
  - every root step (install, initramfs rebuild, enabling the theme) is a command the owner runs;
  - a broken theme must never hide the disk-password prompt: a tested fallback to the text prompt;
  - the last identity step, after the lock steps.
  Until then Omarchy's path stays, and Grassfield's identity starts at the ground colour.
- **Step 10 as built** (2026-10-31, in the one pull request; ADR-0042, under the opus security review; nothing in
  `shell/security`): the package `grassfield-login-themes` installs `/usr/share/sddm/themes/grassfield` (`Main.qml`,
  `Strings.js`, `metadata.desktop`, `theme.conf`: the lock's layout on the default artwork, tokens only, SDDM's own
  `sddm.login`, the field emptied before the call and after a failure; "Grassfield (uwsm)" selected first) and
  `/usr/share/plymouth/themes/grassfield` (Plymouth's `two-step` module, the ground `#2F6D5F`, the mark white, an entry box,
  bullets, a padlock and a throbber drawn in `packaging/plymouth/build.sh`), and activates nothing: the owner's commands, the
  first-boot Esc test and the reverts are in `docs/owner-setup/login-boot-themes.md`. `grassfield-login-check` knows the
  theme. Tests: `tests/ci/login_themes.py` (logic layer, 58 mutants after the opus reviews), `tests/unit/tst_loginstrings.qml`
  (the picture only from root-written folders), `tests/shell/login_session.sh` (+1),
  `tests/ci/qml_literals.py` (scans the theme). Legal: E41 (the login layout; the mark's boot place and its white build-time
  render, confirmed by the owner on 2026-10-31: « Oui, marque blanche »). NOT VERIFIED (owner, real machine): the theme in `sddm-greeter-qt6`, SDDM's fallback, the
  boot screen with the disk password, Esc to the text prompt, the reverts.

### 4. Lock screen (security module: display only, opus security review, R12)
- **Backdrop (IQ-W4, owner: A, sharp, banded scrim).** The prepared still of the output's current wallpaper, sharp (the artwork, drawn
  as today, when the wallpaper is an artwork); the scrim `lock.dimOpacity` 0.6 under the date and clock band and under
  the name and field band, `lock.scrimClearOpacity` 0.25 between them, the band edges `lock.scrimFeather` wide and
  outside every text line at every text scale. A2 is computed per band (`test_contrast_tokens.py` lock roles) and
  measured (`contrast.sh --surfaces lock`). Mockup: `mockups/l1-lock.svg`.
- **Ready before it is needed (ID-7).** The lock keeps one decoded still per output, loaded when the wallpaper changes,
  not when the session locks; the avatar picture and the full name are resolved at shell start and on account change;
  the lock surface's colour is the ground under the scrim, not black; the clock is refreshed on resume, before the first
  frame after a wake (T-14). Once the lock shows, nothing on it changes but its own fade (L-3, L-4).
- **Motion (IQ-T2, owner: A, 200 ms fades).** Lock: engaged at once; inside the surface, scrim and text fade in over
  `lock.fadeInMs` 200 (from the idle dim's level when the lock follows it, ID-8). Unlock: after PAM success a new
  machine state `releasing` fades text and scrim out over `lock.fadeOutMs` 200 and only then sets `locked = false`.
  Reduce Motion: cuts. The fades take ADR-0039's `motion.*` role where one fits (its Q6), else these tokens.
- **Unchanged.** The layout and its tokens, the field, the shake, the messages, the reserved hint line (L-5), one surface
  per output, gate L4 (no window or notification content).
- **Invariants for the reviewer.** Engaging the lock never waits for the still, the avatar, the name, the settings or a
  fade. The release happens only after PAM success and after the fade; any event during `releasing` (a lock request, a
  lost lock, an error, a timeout, a shell exit) leaves the session locked and brings the content back, and unlocking
  then needs a new PAM success: the interrupted one is spent (review of ed21d46). The still is
  Grassfield's own JPEG in the 0700 cache, a regular file of at most `wallpaper.lockStillMaxBytes`, decoded at screen
  size; any failure shows the artwork; no user original and no video decoder enters the module (ADR-0016 §6). Tests:
  L1 to L5, `tests/security/reload_locked.sh`, and new cases (a fade interrupted by a new lock; a missing still; a
  release refused during the fade; the first lock right after shell start).

### 5. Session transitions (the proposed sequence of each; storyboards in `mockups/t1-transitions.svg`)

| Transition | Today (audit) | Proposed | Where; step |
|---|---|---|---|
| Boot to session | Omarchy's boot, disk password, autologin; Hyprland `#1C1C1E` (T-1) | Omarchy's path until step 10 brings the login and boot themes (IQ-L1 C); the session's Hyprland background is the default artwork's ground; the shell sets the current ground at start and on change (ID-2) | `config/hypr/grassfield/looknfeel.lua`, shell; step 3 |
| Login to desktop, desktop loading | `#1C1C1E`, the menu bar alone, the artwork fading in, then the picture and a bar tone switch; the menu bar from the defaults before the settings; an auto-hidden menu bar slides away (T-2 to T-8; the Dock and the desktop icons already appear once, final, since 8b5efac) | ground; the wallpaper's cached still (ID-3); once the settings are read (ID-5) and every surface has its final content, menu bar, Dock and desktop icons in one 250 ms fade (ID-20), the Dock's own one-frame reveal joining it; the menu bar's auto-hide starts at rest as the Dock's does (ID-6); P5 counts the wallpaper | `shell/desktop`, `shell/menubar`, `shell/dock`, `shell.qml`, `windows.lua`; steps 3 and 6 |
| Lock | black first frame [inference], blurred artwork, no fade (L-3, W-9) | same picture, windows go, scrim and text fade in (IQ-T2 A, IQ-W4 A) | `shell/security/lock`; steps 4a and 4b |
| Unlock | hard cut to another picture (L-3) | fade out while locked, then release | step 4b |
| Idle dim, then lock | the dim drops before the lock is up [inference] (T-10) | the dim stays until the lock holds; the lock's content starts at the dim's level (ID-8) | `shell/security/idle`; step 5 |
| Displays off, then lock | the displays light up to draw the lock (T-11) | lock at display-off or at the inactivity limit, whichever comes first; at display-off the lock is drawn just before the displays go off (IQ-T4 A) | `shell/security/idle`, Settings > Lock Screen; step 5 |
| Screen saver, then lock | the saver goes before the lock is up [inference] (T-12) | the saver stays until the lock holds (ID-8) | `shell/saver`; step 5 |
| Sleep | locked before sleep when confirmed; exceptions show the desktop on wake (T-13) | unchanged path; the exceptions stay a documented limit (the budget is the system's) | — |
| Wake | the clock may show the sleep time, then jump (T-14) | clock refreshed on resume before the first frame (ID-7); the lock's picture and name already final | step 4a |
| Shell restart | bars vanish, windows over `#1C1C1E`, the whole start again; red screen when locked (T-15) | windows over the ground; the cached still and the single entrance; the red screen delayed past a normal restart, black meanwhile (IQ-T5 A) | steps 3, 5, 6 |
| Log out, restart, shut down | no countdown; layers vanish one by one (T-16) | 60 s countdown (ID-21); after the windows close, one fade of the whole screen to the ground then black, then the session ends (ID-10) | `shell/overlay/SystemMenu.qml`, `packaging/bin/grassfield-session-end`; step 7 |
| Output added or removed | black lock surface [inference] (L-6) | the new output's wallpaper and lock surfaces start at the ground and show its still (ID-15) | step 3 (the wallpaper), step 4a (the lock surface) |
| Appearance switch | the wallpaper does not change (W-3) | crossfade between the artwork's variant sets; tone at the midpoint (ID-14) | step 2 |
| Time of day | (none) | a 20 s crossfade at each phase boundary, deferred during a drag or a full-screen window (IQ-W1 C) | step 2 |
| Wallpaper change | crossfade (ADR-0016) | unchanged | — |

Step 6 as built (ID-20, ID-5, ID-6; 2026-10-31, in the one pull request). The entrance is a latch,
`shell/services/Entrance.qml` (its rule pure in `EntranceLogic.js`): every surface says it is expected when it is created
(`wallpaper:<output>`, `menubar:<output>`, `dock`, `icons:<output>`) and ready when its content is final (the wallpaper's
first frame, step 3; the menu bar once the settings are read; the Dock's first settled layout; the desktop icons' first
layout); `revealed` latches once all are, or after `session.revealTimeoutMs` (1500), and never goes back (a surface created
later is simply shown). Then the menu bar (band and content), the Dock and the desktop icons fade in together over
`session.revealMs` (250; Reduce Motion caps it); the wallpaper is not part of the fade, it is there first. The Dock's
latched `reveal` now also waits for the entrance (its mask, blur and exclusive zone switch with it). Settings first (ID-5):
`Entrance.settingsFinal` once `Settings.loaded`, or `session.settingsWaitMs` (500) after the start, logged, with the
defaults. The menu bar's auto-hide starts at rest (ID-6): when its settings are final its machine is
`AutoHide.initial(autoHides)`, as the Dock's, so an auto-hidden bar is never shown and slid away. P5 counts the entrance:
the bar's `UsableProbe` is armed only once it is shown, and the Dock's probe follows its reveal. Journal: `grassfield-shell:
entrance (ready|timeout[; waited for <keys>])`, and `shown`/`hidden` lines for `menubar` and `dock`. Tests:
`tests/unit/tst_entrance.qml` (the latch, the tokens, the wiring of the four surfaces), `tests/shell/startup_settle_wiring.sh`
(unchanged, passes), and the nested `tests/visual/appear-once.sh` (section 7: first wallpaper kind equals the final one, no
surface shown twice, the menu bar and the Dock after their output's wallpaper, the entrance logged (a timeout reported,
not failed), one bar tone in the first 3 s; at a start and at a restart). Review of 3a5e1b80 (FAIL: MAJOR the bar's blur
before the entrance; MINOR the auto-hide state set before the settings or the full-screen state were final, the bound equal
to the wallpaper's, the Dock ready before it was placed, input on the invisible bar and icons, the script ending on a
missing line under `set -e`; NITs) → fixed: the blur and the bar's input wait for the entrance; the auto-hide machine is
set again until and at the entrance; on its bound the latch still waits for every wallpaper's first frame (which has its
own); the Dock's own window says it is ready once placed; the icons take no pointer input before it and are ready when
hidden; a surface that goes first is forgotten (`Entrance.forget`); the script's reads tolerate a missing line and the Dock
is compared with its own output's wallpaper. `shown menubar` and `shown dock` mean their entrance, auto-hidden or not. NOT VERIFIED: `appear-once.sh` was not run (no nested session in this container), nor P5 on
the owner's logins.

Step 7 as built (ID-21, ID-10). Log Out, Restart and Shut Down, from the System menu and from Search, confirm with the
countdown as their message ("If you do nothing, the computer will restart automatically in 60 seconds.", one second at a
time from `session.exitCountdownSeconds`; one and many as separate strings); left alone, the dialog confirms itself
(`PopupKinds.countsDown`, `countdownMessage`; Force Quit and Empty Trash never act without a click). Closing the dialog stops
the count: Cancel, Esc, another popup in its place, and the lock (`Lock.qml` closes every popup as it locks, so a countdown
never ends the session from behind the lock screen; whether macOS's count goes on under its lock is NOT VERIFIED, and the
stop is the safe side; nothing in `shell/security` changes). Settings > Software Update's own Log Out… and Restart… sheets
keep their message until that panel's lane has merged. Once `grassfield-session-end` has seen every window go (or the user
chose "… Anyway", or `--force`), it asks the shell for the exit cover (`qs ipc -p /usr/share/grassfield/shell call session
cover`, Quickshell's option variables cleared) and waits for the fade it answers (`session.exitFadeMs`; Reduce Motion
`motion.reducedMax`), the ask included at most `session.exitWaitMs`; a shell that does not answer costs nothing but the fade.
The cover (`shell/overlay/ExitCover.qml`) is one opaque `grassfield-exit-cover` surface per output on the overlay layer, in
the ground's colour, faded by the shell alone (`gf-exit-cover-no-anim` in `windows.lua`, ID-4); the black after it is the
greeter's or the firmware's (`mockups/t1-transitions.svg`). When the session then cannot be ended (`uwsm stop` and the
compositor's exit both fail, or `systemctl` refuses), the helper lifts the cover and exits 4; a cover nobody lifts (the
helper was killed) lifts itself after `session.exitCoverHoldMs`; `session cover` and `lift` are actions of the shell's IPC
surface (`docs/specs/security.md`: another process of the user can hide the desktop for that long at most), `session
state` a dev hook. Since step 3 the ground is the shown wallpaper's (`Ground.current`, which the shell also sets as
Hyprland's background colour), `session.ground` the static default (`tests/unit/tst_sessionexit.qml`). Tests: `tst_popupkinds.qml`,
`tst_sessionexit.qml`, `tests/shell/session_end.sh` (the helper against a stand-in `qs`: the real one would reach the
session's shell), `tests/fuzz/fuzz_helpers.py` session-end (the wait stays within `EXIT_WAIT` whatever the shell answers).
Legal (ID-17): E2 of `docs/legal/visual-review.md` adds the countdown, its macOS-like sentences and the exit fade.

### 6. Tokens and contract (proposed; every value an estimate until F1 and P3)
| Token or key | Value | Note |
|---|---|---|
| `artwork.<name>.<variant>.<role>` | the palettes of `mockups.py` (`PAL`, `meadow`, `rows`, `ridgeline`) | ID-1; `evening` keeps today's values (`GrassfieldArtwork.qml:12-21`) |
| `session.settingsWaitMs` | 500 | ID-5 |
| `session.revealTimeoutMs` | 1500 | the latch's bound (P-6) |
| `session.revealMs` | 250 | ID-20 (ASSUMPTION for macOS); an ADR-0039 `motion.*` role where one fits |
| `session.exitFadeMs`, `session.exitWaitMs` | 400, 1000 | ID-10 |
| `session.exitCountdownSeconds` | 60 | ID-21 (step 7) |
| `session.exitCoverHoldMs` | 20000 | ID-10, P-6: a cover nobody lifted lifts itself (step 7) |
| `session.ground` | `#2F6D5F` since step 3 (the default artwork's ground; `#1E1C18` in step 7), the session's static Hyprland background colour | ID-2: the shown wallpaper's ground replaces it at run time (step 3) |
| `wallpaper.firstShowTimeoutMs` | 1500 | ID-3 |
| `lock.fadeInMs`, `lock.fadeOutMs` | 200, 200 | IQ-T2 A |
| `lock.scrimClearOpacity`, `lock.scrimFeather` | 0.25, 48 | IQ-W4 A; A2 per band |
| `wallpaper.artwork` | `grassfield` \| `meadow` \| `rows` \| `ridgeline` | additive key, default `grassfield` |
| `wallpaper.artworkVariant` | `timeOfDay` \| `automatic` \| `light` \| `dark` | additive, default `timeOfDay` (IQ-W1 C; the Grassfield artwork only) |
| `wallpaper.phaseFadeMs` | 20000 | IQ-W1 C, the slow crossfade between two phases |
| `wallpaper.phaseDawnBeforeSunriseMin`, `phaseDayAfterSunriseMin`, `phaseEveningBeforeSunsetMin`, `phaseNightAfterSunsetMin` | 30, 90, 90, 30 | IQ-W1 C |
| `wallpaper.phaseFixedDawn`, `phaseFixedDay`, `phaseFixedEvening`, `phaseFixedNight` | "06:00", "08:00", "18:00", "20:30" | IQ-W1 C, where the zone gives no point or the sun neither rises nor sets |
| `artwork.grassfield.<dawn\|day\|evening\|night>.<light\|dark>.<role>` | the light set from `mockups.py`; the dark set derived and A2-checked in step 2 | IQ-W1 C; `evening.dark` keeps today's values |
| `wallpaper.moving` | bool, false | IQ-W3 A, in 1.0 |
| `lock.requirePasswordAfterDisplayOff` | `immediately` \| `5s` \| `1m` \| `5m` \| `15m` \| `1h` \| `never`, default `immediately` | IQ-T4 A; beside `lock.idleMinutes`, which stays the ceiling, so nothing migrates (ADR-0020 row) |
| `$XDG_STATE_HOME/grassfield/wallpaper.json` | gains the last shown still per output (path, statistics, ground) | ID-3; ADR-0020 row in that step |

### 7. How "appears once" is measured
- **Journal.** Each surface logs `grassfield-shell: shown <surface> <output> <ms>` when it becomes visible and `hidden`
  when it goes; the wallpaper also logs its first kind and source.
- **Test** `tests/visual/appear-once.sh` (nested, light appearance, a picture wallpaper, a non-default accent): at shell
  start and at a restart, the first wallpaper kind equals the final one, no surface is shown twice without being
  hidden, the bars come after the wallpaper, the bar tone does not change in the first 3 s; at lock and unlock, the
  journal order and `grim` captures every 50 ms (the still's pixels outside the text bands equal the desktop's).
  Captures are the visual evidence.
- **Gates.** P5 counts the wallpaper and the entrance (≤ 2 s from the uwsm start line); P3 covers the appearance
  crossfade and the lock fades; P2 the preloaded stills (one per output); A2 the new artworks and the lock bands;
  L1 to L5 every lock and idle step; Q2 no QML error on any path.

## Owner questions (as asked; answered on 2026-10-29, see "Owner decisions (2026-10-29)")

**IQ-W1. The default wallpaper, light and dark.** Mockup `w1-default-wallpaper.svg`.
| Option | For | Against |
|---|---|---|
| **A. Day in the light appearance, today's artwork ("Evening") in the dark one (recommended)** | the default dark desktop stays exactly as today; the light appearance gets a matching daylight scene; one geometry, recognisable in both | the dark variant keeps a bright sun and horizon; light-appearance users see a new picture |
| B. Day, and a new darker "Night" (stars, a small moon); today's artwork stays in the collection as "Evening" | a truly dark desktop at night, less glare | the default desktop changes for everyone; near-black hills make the dark glass read as near-black plates |
| C. The time of day: Dawn, Day, Evening, Night by local time | macOS's dynamic-desktop idea, a living desktop | four crossfades a day and a changing bar tone during work; needs sunrise times (location) or fixed hours; not tied to the appearance |

**IQ-W2. The shipped collection.** Mockup `w2-collection.svg`.
| Option | For | Against |
|---|---|---|
| **A. Four procedural artworks, light and dark: Grassfield, Meadow, Field Rows, Ridgeline; plus the colours (recommended)** | made here (CC-BY-SA-4.0), crisp at any size, almost no package weight, tone and A2 known by construction | six new palettes to tune and test (A2, F1, the side-by-side legal check); less rich than photography |
| B. Only the Grassfield pair and the colours | least work, one strong image | little choice before the user brings pictures |
| C. A and photographs (commissioned, or CC0 / CC BY from Wikimedia Commons) as image files | macOS-like richness | a licence and provenance per file, 3-6 MB per 5K picture, the helper's parse path, possible resemblance with well-known OS photos |

**IQ-W3. Videos** (recommendation changed by the review of b44d17e).
| Option | For | Against |
|---|---|---|
| A. No video file; an optional moving variant of the default drawn live, off by default, with the video pause rules; also a screen saver kind | no package weight, no codec, no new licence; motion in the brand scene; pauses like a video | a new feature during the release candidate; GPU work while visible (the Dock and popups re-blur every frame, as with any video), so P1 and P3 first |
| **B. No motion in 1.0; A after 1.0 (recommended)** | nothing new to stabilise before 1.0; nothing to measure now | no answer to macOS's video wallpapers in 1.0 but "add your own" |
| C. Pre-rendered H.264 loops of the artwork | hardware decode, same path as user videos | 20-60 MB per loop, a build-time renderer, FFmpeg (G9) in the shell by default |

**IQ-W4. The lock screen's backdrop** (ADR-0016 Q4 was settled on 2026-10-20 as its recommended option, a sharp still
under the existing scrim, an integrator decision the owner can revisit; this asks whether the scrim stays flat now that
the identity is designed). Mockup `l1-lock.svg`.
| Option | For | Against |
|---|---|---|
| **A. The user's wallpaper, sharp; scrim 0.6 only under the text bands, 0.25 between (recommended)** | shows the wallpaper as macOS does (ASSUMPTION) and as the desktop does; A2 holds where text is | band geometry to prove at every text scale; security review |
| B. Sharp, with today's flat 0.6 scrim (ADR-0016 Q4 as settled) | simplest; A2 already computed | the picture reads dim and grey |
| C. Blurred, flat scrim (today's look with the user's wallpaper) | calm; hides busy pictures | blur cost per output; less continuity with the desktop |

**IQ-B1. The mark: where it appears, in what colour, and the rules of its use** (the mark itself is not changed; the
rules are the owner's to set, review of b44d17e). Mockup `b1-logo-use.svg`.
- Rules proposed with every option (the owner may change any of them): clear space of a quarter of the mark's height on
  every side; 14 px smallest; never stretched, rotated, outlined, given a gradient or a shadow, or redrawn; only the
  file's own path, at run time.

| Option | For | Against |
|---|---|---|
| A. As today: monochrome everywhere, also as the default glyph of shell dialogs | no change | the mark stands for "a dialog" (restart, notices); no brand moment |
| **B. Fewer, deliberate places: the menu bar (monochrome), About and Settings > About (Grassfield green), Search; dialogs show their subject's symbol (recommended)** | the mark means "Grassfield" only; colour on brand moments, a neutral chrome | each dialog needs its own symbol (most exist in the symbolic set) |
| C. As B, in the user's accent instead of the Grassfield green | follows personalisation | the brand colour disappears when the accent changes |

**IQ-B2. The name next to the mark.**
| Option | For | Against |
|---|---|---|
| **A. No lockup in 1.0: the mark alone as the symbol, the name in running text (recommended)** | nothing new to protect or clear; the macOS UI has no wordmark either | no single "mark and name" image for the README or packages |
| B. A fixed lockup: the mark and "Grassfield" in Inter Display Semibold (mockup) | cheap and consistent | not distinctive (a common font); its rights status is the owner's to set; needs legal review (OFL font in a logo) |
| C. A designer-made wordmark, with ADR-0014's planned icon redraw | distinctive, protectable | cost and time; after 1.0 |

**IQ-B3. The default accent's name and the second green** (asked with ADR-0039's Q4, already answered as D-Q4: the
switches and slider fills move to the selection fill; IQ-B3 changes the palette, not which controls read it). Mockup
`b2-accent.svg`.
| Option | For | Against |
|---|---|---|
| **A. The default is named "Grassfield" (a green swatch); the pickable Green moves away from the brand green (recommended)** | the brand colour is named; no two near greens | departs from macOS's "Multicolour"; users who chose Green see it change; **the Settings tiles drawn in that Green change with it** (the sidebar's Battery and Motion, `Main.qml:27, 32`; rows of Accessibility, Menu Bar, Software Update and Storage) |
| B. Keep "Multicolour" and both greens | macOS's model and name | "Multicolour" means one green here; two greens read alike |
| C. Keep "Multicolour", drop the pickable Green | no near-duplicate | seven colours; users of Green move to the default; the Settings tiles in Green need another colour |

**IQ-B5. The icons of Grassfield's own apps** (the owner decided on 2026-10-23 that system apps take the pack's icons;
recommendation changed by the review of b44d17e). Mockup `b4-app-icons.svg`.
| Option | For | Against |
|---|---|---|
| A. As today: the pack for Files, Settings and Preview, Store's own icon, Activity Monitor and the Apps tile from the pack | one look with the pack | Grassfield-only apps carry no brand; Store differs from the rest |
| B. Grassfield's own icons on one grammar for every Grassfield app; the `org.grassfield.*` aliases go | the apps carry the brand; Grassfield's drawings instead of the macOS look-alike pack for its own apps | reverses the 2026-10-23 rule for three apps; our drawings sit beside the pack's richer ones until a designer redraw |
| **C. Own icons, on one grammar, only where the pack has no system app of that role: Store, Activity Monitor, the Apps tile; the pack for Files, Settings, Preview (recommended)** | keeps the owner's rule of 2026-10-23; the brand appears on the apps only Grassfield has | two looks among Grassfield's own apps; the two new drawings need the owner's legal call (E39) |

**IQ-L1. From power-on to the desktop.**
| Option | For | Against |
|---|---|---|
| **A. Omarchy's path unchanged (Limine, disk password, SDDM autologin); Grassfield starts at the ground (recommended)** | no greeter or boot change (a non-goal; R12), no root work | the boot and disk-password screens are Omarchy's look |
| B. A Grassfield SDDM theme in the lock screen's layout, for machines without autologin (own ADR, opus security review, SDDM's own PAM service) | a macOS-like login window | a non-goal today ("allowed later"); SDDM runs as its own user (no access to the user's wallpaper: the default artwork only); owner-only tests |
| C. B and a Plymouth theme with the mark for boot and the disk password | identity from power-on | initramfs and boot configuration (root, owner-run, M6 territory); a broken theme can hide the disk prompt |

**IQ-T2. Lock and unlock motion.** Mockups `l1-lock.svg`, `t1-transitions.svg`.
| Option | For | Against |
|---|---|---|
| **A. Lock at once, then scrim and text fade in (200 ms); unlock: fade out while still locked (200 ms), then release (recommended)** | continuity; the release still follows PAM, any failure stays locked | unlock 200 ms longer; a new lock-machine state; security review |
| B. No motion (today) | nothing to review | hard cuts both ways |

**IQ-T4. When the displays turn off before the lock** (rewritten by the review of ed21d46: following display-off
alone is not stricter than today). Defaults today: displays off after 2 min on battery and 10 min on AC
(`lock.displayOffBattery`, `lock.displayOffPower`), lock after 5 min (`lock.idleMinutes`), screen saver off. A lock that
only followed display-off would come at 10 min on AC instead of 5, and never with display-off set to Never and the
saver off; that form is not offered.
| Option | For | Against |
|---|---|---|
| **A. Lock at display-off or at "Require password after inactivity" (`lock.idleMinutes`), whichever comes first; at display-off the lock is drawn just before the displays go off; a new "Require password after the display turns off" (Immediately by default, as macOS) (recommended)** | no lit flash with the defaults; never later than today (the inactivity limit stays the ceiling), earlier where the displays go off first (2 min on battery by default instead of 5) | on battery, more password prompts by default (2 min instead of 5); one more setting; with a delay other than Immediately the lock comes while the displays are off and the flash returns for those users (unless Hyprland confirms a lock without drawing: VERIFY) |
| B. Keep the inactivity model; turn the displays off only once the lock holds | no flash, no new setting, the lock time unchanged | on battery by default the screen stays lit 5 min instead of 2; "Turn display off after" is no longer honoured when it is shorter than the lock |
| C. Today: lock after N minutes of inactivity; the displays light up to draw it | no change | a lit flash with the default settings on battery (off at 2 min, lock at 5) |

**IQ-T5. The compositor's red "lock screen died" screen during a shell restart** (was ID-9; it reverses a security
choice, H10, so it is the owner's: review of b44d17e). Hyprland 0.56.2 has `misc:lockdead_screen_delay` (the
integrator's check). The session stays locked by the compositor either way (`allow_session_lock_restore`); only what is
drawn while the shell restarts changes.
| Option | For | Against |
|---|---|---|
| **A. Delay it past a normal restart (the shell is back in about 1-2 s): the screen stays black meanwhile; a shell that does not come back still shows the red screen after the delay (recommended)** | no red flash on a crash-and-restart that recovers by itself | the user learns later that the lock died; the nested pass must show only black during the delay |
| B. Keep it at once (H10 as decided) | the failure is visible at once | a red screen on every locked restart, even one that recovers within a second |

**Not a design question (needs legal review).** STATE records that the owner did the "Grassfield" trademark check
(2026-10-18); the legal dossier says no clearance search was made and the owner decided "no logo clearance"
(2026-10-27) (B-5). Which record is right is the owner's to say; this ADR changes neither.

## Owner decisions (2026-10-29)
Asked by the integrator from this ADR's options, with the recommendations shown; recorded on pull request #46
("The owner's answers to ADR-0040's questions"). The owner's choices as shown, in French, then the option.

| Question | Owner's choice | Option |
|---|---|---|
| IQ-W1 default wallpaper | « Selon l'heure » | **C**: the time of day (Dawn, Day, Evening, Night) |
| IQ-W2 collection | « Dessins + photos » | **C**: the four artworks and photographs |
| IQ-W3 videos | « Animation dessinée » | **A**: a moving variant drawn live, off by default, with the video pause rules, in 1.0 |
| IQ-W4 lock backdrop | « Net, voile par bandes » | **A** (recommended) |
| IQ-B1 the mark | « Peu d'endroits, vert » | **B** (recommended) |
| IQ-B2 the name | « Pas de logotype » | **A** (recommended) |
| IQ-B3 accent | « Grassfield » | **A** (recommended) |
| IQ-B5 app icons | « Propres là où le pack n'a rien » | **C** (recommended) |
| IQ-L1 power-on | « Connexion + démarrage » | **C**: an SDDM theme and a Plymouth theme |
| IQ-T2 lock motion | « Fondus de 200 ms » | **A** (recommended) |
| IQ-T4 display-off | « Au 1er des deux » | **A** (recommended, as rewritten after the review of ed21d46) |
| IQ-T5 red lock-died screen | « Le retarder » | **A** (recommended) |
| B-5 trademark record | « J'ai vérifié le nom » | The owner checked the **name** "Grassfield" on 2026-10-18 and **not the logo** (no logo clearance, 2026-10-27). The legal dossier is corrected (E33, Q7, section 7); STATE stays. |

**Step 1c's Green (2026-10-30).** Asked when step 1c started, the brand green and the pickable Green being 0.04 apart
(OKLab) in the light appearance; two values shown against today's (a capture of the accent row and the tiles in both
appearances): « B : vert clair, comme macOS » (`#6DB53C`, dark text; not the recommended A, a dark green `#2D5A04` with
white text). The costs named in the question and taken: the white glyphs of the green Settings tiles at 2.5:1, and green
joins yellow among the light accents with dark marks (its selection pair; ADR-0039 step 11's knob on the "on" fill).

**The brand green and the neutrals (2026-10-30).** Shown a comparison board (the current brand green and a deeper,
calmer one, each with today's cool neutrals and with warm ones, in both appearances, on the default artwork with a
Settings window): « B en clair seulement, et neutres chauds ». The brand green of the light appearance becomes `#195E3F`
(white text 7.7:1, where `#26763F` gave 5.6:1); the dark appearance keeps `#4FB36B` (its deeper candidate `#4F9F77`
was 4.5:1 on the window, 5.2:1 under its dark text). The neutrals turn warm in both appearances, an explicit choice over
the "closest to macOS 27" rule; they come in their own pull request (they cross ADR-0039's neutrals and glass and the
plugin's title bar), measured first in a scratch copy: every A2 role holds, three pinned values move.
As built (after pull request #71): 34 neutral tokens move to hue 85, chroma 0.0075 in OKLCH, each keeping its lightness
(so each contrast stays), the pure white to `#FDFCF9`: `color.light` and `color.dark` text, secondary texts, window,
group, sidebar, field, chip and material tint; the plugin's `titlebar.*` (background, title, inactive buttons, the
preview tint); `window.inactiveLight*`; `folderIcon.plateBackdrop*`; `menu.swatchMark`, `preview.paperInk`,
`store.accountCircleFill`. Kept: the black and white inks drawn at an alpha (hover, separators, shadows, fills, borders),
the opaque white knob, the Graphite accent and its selection, Files' Gray tag and the drawing of the computer
(`settings.device*`).
Follow-up (the integrator's decision on #73, the owner's « Faire le suivi GTK » of 2026-10-31): the GTK themes but `-hc`
lay the warm grounds (window `groupFill`, views, lists, menus and popovers `windowBackground`, header bars the plugin's
title bar colour, text `text`; ADR-0035 D-8), and the session's Hyprland ground is `#1E1C18` (`#1C1C1E` warmed) until step
3 makes it the default artwork's ground (ID-2).
Re-pinned: the light glass's worst-case alpha 0.78 to 0.79 (`test_contrast_tokens.py`, `tst_glasstint.qml`), the GTK
themes' thin marks under high contrast (yellow 1.97:1, green 2.46:1), and the tests that named the old greys.

**The photographs (step 2c, 2026-10-31).** Shown the list (a review page: each photograph's thumbnail cropped to 16:10
under the menu bar and the Dock, its Commons page, licence, author, size, the closest well-known OS wallpaper and what to
know), the owner kept all sixteen and answered the three licence questions: « domaine public (04, 16) : acceptées »
(a deliberate exception to the integrator's "CC0 or CC BY": 04 was released into the public domain by its author, 16 is
a work of the U.S. federal government whose status does not cover the agency's name or logo, neither shown);
« Unsplash (01, 15) : CC0 de Commons accepté » (published on Unsplash before 2017-06-05, when it was CC0, and uploaded to
Commons in 2017 from archived pages; Commons marks them CC0); « FIND/47 (08, 12) : acceptées » (the source library
states CC BY 4.0 for all its photos, checked on its page; Commons has no licence review on these two files). The
resemblance notes shown with them: 08 is the closest of the list to Windows XP's "Bliss" and 12 recalls macOS Big Sur's
coast at dusk; the side-by-side check of E32 before release covers them. Found on Wikimedia Commons (the licence read
from each file page); 55 other files were rejected (CC BY-SA, a look-alike of an OS wallpaper, a person, a vehicle, a
watermark, flat light). The originals weigh 235.4 MB together; the files, their `docs/legal` entries (source, author,
licence, date, changes made), the install path and the package weight come with step 2c's pull request.

| No. | Commons file | Author | Licence | Original |
|---|---|---|---|---|
| 01 | `Matt Palmer 2016 (Unsplash).jpg` | Matt Palmer (Unsplash) | CC0 | 5760 × 3840, 14.3 MB |
| 02 | `Łąki nad Wisłą pod Brzeźnicą po wschodzie słońca, 20241116 0725 2676.jpg` | Jakub Hałun | CC BY 4.0 | 4807 × 3198, 9.1 MB |
| 03 | `Zamglona dolina w Witowie w powiecie proszowickim, 20241020 0808 6322.jpg` | Jakub Hałun | CC BY 4.0 | 5340 × 3566, 12.5 MB |
| 04 | `Desna river Vinn meadow 2016 G2.jpg` | George Chernilevsky | public domain (PD-self) | 6000 × 4000, 8.9 MB |
| 05 | `Чуйский хребет и Курайская степь.jpg` | Aleksandr Rudny | CC BY 4.0 | 4857 × 2732, 8.1 MB |
| 06 | `Tatry - panorama z Polskiego Spiszu.jpg` | Qvidemus | CC BY 3.0 | 8364 × 4850, 28.8 MB |
| 07 | `Ingushetia, Закатный золотой свет на склонах долины Армхи, горы Ингушетии, Кавказ.jpg` | Vyacheslav Argenberg | CC BY 4.0 | 6000 × 4000, 19.4 MB |
| 08 | `Hyogo-Rice terraces in Ueyama.(early autumn.)-xl.jpg` | rikky_photography (FIND/47) | CC BY 4.0 | 6000 × 4000, 30.2 MB |
| 09 | `Dew on grass (21677746153).jpg` | Andrey Nagaycev | CC BY 2.0 | 5616 × 3744, 10.3 MB |
| 10 | `Grass (14448015527).jpg` | Yuri Samoilov | CC BY 2.0 | 5760 × 3840, 4.0 MB |
| 11 | `Grass at Sunrise (36993588030).jpg` | Mikhail Lazarev | CC BY 2.0 | 6000 × 4000, 6.1 MB |
| 12 | `Kyoto-Evening view of Sodeshi rice terraces.-xl.jpg` | rikky_photography (FIND/47) | CC BY 4.0 | 6000 × 4000, 25.0 MB |
| 13 | `Wschód słońca nad łąkami pod Tyńcem w Krakowie, 20260301 0636 4894.jpg` | Jakub Hałun | CC BY 4.0 | 4686 × 3118, 13.6 MB |
| 14 | `Dew on grass (22309335571).jpg` | Andrey Nagaycev | CC BY 2.0 | 5616 × 3744, 10.9 MB |
| 15 | `Waving grass under mountains (Unsplash).jpg` | Thomas Rohlfs (Unsplash) | CC0 | 4608 × 2592, 9.2 MB |
| 16 | `Milky Way over Cronan Ranch (52321033535).jpg` | Bureau of Land Management California | public domain (PD-USGov-BLM) | 6965 × 4752, 25.0 MB |

**The rest in one pull request (2026-10-31).** With the integrator away, the owner asked for every remaining step in one
pull request (« Fait tout jusqu'à la fin dans une même PR ... sauf s'il te demande d'arrêter de travailler »): pull request
#79 carries #73's GTK follow-up, step 7, step 2c and then steps 2, 3, 4a, 4b, 5, 6, 8, 9 and 10, one commit series per step
in the delivery plan's order, each pushed when its checks pass, so the integrator can stop the work at any commit. The
owner lifted, for this chantier, the rule that kept `shell/desktop`, `shell/menubar`, `shell/dock`, `Appearance.qml`,
`apps/store` and `apps/activity` to their own lanes (« Oui, touche-les »; no open pull request worked there that day). IQ-L1
C: the owner's explicit go-ahead for Plymouth as well as SDDM (« SDDM et Plymouth »), given with the conditions as asked:
plymouthd runs as root in the boot image and draws the disk-password prompt; a broken theme must never hide it (a fallback
to the text prompt, which this container cannot test); every root step is the owner's command. The security steps (4a,
4b, 5, 10) keep their opus security review before any merge; the review of each is recorded in "Review history".

**The integrator's conditions for the non-recommended choices** (2026-10-29, under the owner's rule: closest to macOS
27, no technical step for the end user), written into the sections they shape:
- **W1 C, the time of day** (section 2, "The time-of-day rule"): the times from the time zone with no location and no
  network (the zone's reference point, or fixed hours where the zone gives none); slow crossfades, never during a drag
  or a full-screen app; A2 proven for the band at every phase; light and dark still choose the variant set; the exact
  rule in this ADR before it is built.
- **W2 C, artworks and photographs** (section 2, "Photographs"): a licence and provenance entry per photograph (CC0 or
  CC BY, or commissioned with a written licence); no resemblance to a well-known OS wallpaper; the list to the owner for
  the legal call before it ships; the package weight stated in the pull request.
- **W3 A, the drawn animation in 1.0** (section 2, "Videos"): off by default; it pauses like a video (hidden, battery
  saver, a full-screen app, locked); P1 and P3 measured with it on before the pull request asks for a merge; a cost
  over budget blocks it.
- **L1 C, SDDM and Plymouth** (section 3, "Boot and login"): its own ADR, an opus security review, SDDM's own PAM
  service, nothing changed in Omarchy's Limine or disk-encryption flow beyond the theme; every root step is the owner's
  command; a broken theme never hides the disk-password prompt (a tested fallback to the text prompt); the last identity
  step, after the lock steps.

## Decisions taken under the owner's rule (2026-10-28: the closest to macOS 27, no technical step for the end user)
- **ID-1** The artwork palettes become tokens (`artwork.*`, section 6) with source notes; the written exception in
  `GrassfieldArtwork.qml:5-7` goes, so the "tokens only" rule has no exception left in the wallpaper. ADR-0039's step 2
  allowlists those colours until then.
- **ID-2** One ground colour (P-1). The session's Hyprland `background_color` is the default artwork's ground; the shell
  sets the current one at start and on change through the session's own compositor path (mechanism VERIFY on 0.56.2;
  fallback: the static default). The wallpaper window's colour (step 3) and the exit cover (step 7) use it; the lock
  surface's colour is the security module's and comes with step 4a (review of b44d17e).
- **ID-2a (amendment, 2026-11-02, rc1-16 defects; decided under the delegation "closest to macOS 27, no technical step for
  the end user")** The default artwork's ground is the static start colour only for an account that has no ground yet. The
  shell records the ground Hyprland accepted in `wallpaper.json` (`ground`), and `looknfeel.lua` starts the next session on
  it (read through `test -f` and `timeout`: a FIFO, a directory or a symlink leave the default), so an owner who chose a
  picture or a colour never sees the default's green first (macOS: the user's own wallpaper from the first frame). ID-3's
  bound is changed in the same way: the default artwork is the FALLBACK of a failed source (an error, a missing file, a
  failed transcode), never a replacement for a wallpaper that is still loading. P-3 holds: on the bound
  (`wallpaper.firstShowTimeoutMs`) a loading wallpaper changes nothing, neither the artwork nor a release of the bars; the
  bar, the Dock and the icons come after the desktop picture, together, at its first frame, or at the entrance's own hard
  bound (the reveal bound plus four wallpaper bounds, 7.5 s; a first prepare at a fractional scale takes 4 to 5 s under load) if it never comes (journal `entrance (hard bound)`). Only a failed source shows the artwork, and with it the bars
  (`entrance (wallpaper error)`). No decode is cancelled (`WallpaperConfig.firstFrameStep`). A stored still is used only for
  the setting it was shown for (`src`).
- **ID-3** The wallpaper's first frame is the cached still of the last applied wallpaper, with its tone (section 2).
- **ID-4** The wallpaper layer gets `no_anim` like the bars; every entrance animation belongs to the shell (one owner of
  motion), so the compositor never fades a layer in under the shell's own fade.
- **ID-5** No surface is shown before the settings are read (`Settings.loaded`), bounded by `session.settingsWaitMs`;
  the Dock already waits for them (8b5efac), the menu bar and the wallpaper follow.
- **ID-6** The menu bar's auto-hide starts at rest at session start, as the Dock's has since 8b5efac (macOS, ASSUMPTION),
  instead of showing and sliding away.
- **ID-7** The lock prepares everything ahead (section 4): the still per output, the avatar, the full name, the surface
  colour, and the clock refresh on resume.
- **ID-8** The idle dim and the screen saver stay until the lock holds; the lock's content starts at the dim's level.
  The lock request itself is not delayed; when it fails, the dim lifts and the failure is logged as today.
- **ID-9** Moved to the owner as IQ-T5 (review of b44d17e).
- **ID-10** The exit cover: `grassfield-session-end` asks the shell for one full-screen fade to the ground then black
  (`session.exitFadeMs`) after the windows have closed, and waits at most `session.exitWaitMs`.
- **ID-11** Settings > About's Grassfield tile uses the brand green, not the pickable Green (B-8).
- **ID-12** Docs and comments call the logo "the Grassfield mark" (B-4: four names today), as each step touches them.
- **ID-13** The copy `ui/Grassfield/Ui/icons-bar/grassfield-logo.svg` gets its row in `branding/LICENSES.md` (all rights
  reserved, the owner's mark): done in this pull request (B-2).
- **ID-14** An appearance switch crossfades between the artwork's variants (two-slot model, one fixed length); the tone
  switches at the midpoint; Reduce Motion cuts.
- **ID-15** A hotplugged output's wallpaper surface (step 3) and lock surface (step 4a, security review) start at the
  ground and show its still.
- **ID-16** The measurement of section 7 lands with step 3 and grows with each step.
- **ID-17** The legal dossier's identity entries are brought up to date as each step lands (E12, E32, E33 now; E2,
  E26, E28 and section 4, stale in passing, at the next legal pass).
- **ID-18** Artwork names avoid the names of macOS wallpapers ("Ridgeline", not "Horizon"; checked from memory only,
  ASSUMPTION: the side-by-side legal check before release covers names and pictures).
- **ID-19** (was IQ-B4; review of b44d17e) About This Computer is computer first, as macOS 27's About This Mac: the
  computer's picture and model name, then the hardware rows, then the product line with the mark and More Info…, which
  opens Settings > General > About. macOS reason: About This Mac leads with the Mac, and the system's name and version
  are one line under it. Options weighed: brand first (unlike macOS 27 and unlike Settings > About), today's sheet (no
  picture, no mark). It becomes a small window; ADR-0039's steps 4 and 10 then no longer touch it.
- **ID-20** (was IQ-T1) Session start: the wallpaper first, then menu bar, Dock and desktop icons together in one fade
  (`session.revealMs`) once all are final, bounded by `session.revealTimeoutMs`. macOS reason: at login the desktop
  picture is there first and the menu bar and Dock come in once (ASSUMPTION; no capture). Weighed: no fade (a hard cut
  from the ground), a splash (not macOS).
- **ID-21** (was IQ-T3) Log out, restart and shut down confirm with macOS's 60-second countdown that proceeds by itself
  ("… automatically in 60 seconds", ASSUMPTION from memory), then the exit cover (ID-10). macOS reason: the same dialog
  and countdown on a Mac. Weighed: today's confirmation with the fade only (not macOS), no confirmation (a misclick ends
  the session).

## Coordination with ADR-0039 (design polish)
The owners are those of ADR-0039's own table ("Coordination with the identity lane"), unchanged. ADR-0039 merged first;
this ADR follows it, and any later pull request of either lane that meets one of these rebases on the other.

| Overlap | Owner | The other lane |
|---|---|---|
| The greens: ADR-0039 Q4 and its step 11 ↔ IQ-B3 | ADR-0040: the accent palette (`color.accent*`, the default's name and swatch) | ADR-0039: which controls read the accent and which the selection fill |
| The neutrals: the owner's warm neutrals of 2026-10-30 ↔ ADR-0024's greys, ADR-0039 Q3 (dark secondary text), Q8 and step 21 (third-party title bars on the window tokens) | ADR-0040: the neutrals' warmth (`color.light` and `color.dark` surfaces and text, `titlebar.*`, `window.inactiveLight*`, the icon plates' backdrop; hue 85, chroma 0.0075, each lightness kept) | ADR-0039: which roles read them, the glass classes and their alphas; its values read warm now (#FFFFFF and #292929 are `#FDFCF9` and `#2B2925`) |
| About: ADR-0039 steps 4 and 10 ↔ ID-19; IQ-B1's dialog glyphs | ADR-0040: About This Computer's form, the glyphs of `NoticeDialog` and `ConfirmDialog` | ADR-0039: `Dialog`'s and `Sheet`'s grammar (radius, buttons, blur radius) |
| `looknfeel.lua`, `windows.lua`, `Compositor.qml`: ADR-0039 steps 6 and 20 ↔ ID-2, ID-4, IQ-T5 | ADR-0040: the ground colour, the first frame and the transitions | ADR-0039: the window border colour per appearance and the compositor's animation curves |
| Motion tokens: ADR-0039 Q6 ↔ the session and lock fades | ADR-0039: `motion.*` | ADR-0040: `session.*` and `lock.*` fades, naming a `motion` role where one fits |
| `shell/saver` | ADR-0040: the saver's transitions (ID-8) | ADR-0039 step 5: its slide crossfade under Reduce Motion |
| Settings' Appearance and Wallpaper pages | ADR-0040: the wallpaper page and the accent row | ADR-0039: the shared controls and the glass preview (its step 15) |
| `GrassfieldArtwork.qml`'s colours | ADR-0040 (ID-1) | ADR-0039 step 2 drops them from its allowlist when ID-1 lands |
| The Dock's and menu bar's auto-hide: ADR-0039 step 25 ↔ step 6 here | ADR-0040: the reveal at login | ADR-0039: Reduce Motion and the easing of auto-hide |
| `tests/visual/test_contrast_tokens.py`, `contrast-roles.json` | ADR-0039: the role table's repair (its step 0b) | ADR-0040: the roles of its own surfaces (the lock's scrim bands) |

## Delivery plan (one pull request per step towards main; split by the review of b44d17e)
| Step | Content | Blocked by | Review |
|---|---|---|---|
| 0 | This ADR, the audit, the mockups, E39, STATE | — | integrator |
| 1a | `DevicePicture` moves from the Settings app into `Grassfield.Ui` (so the shell can draw it), the Settings pages unchanged | — | reviewer; `ui_api.py` and `docs/specs/ui-api.md` |
| 1b | About This Computer as a small window, computer first (ID-19): Settings' own window (`grassfield-settings --about`), the shell's sheet retired | step 1a | reviewer |
| 1c | The accent's name and the second green (IQ-B3 A) with the Settings tiles, the About tile (ID-11) | coordinate with ADR-0039 step 11 | reviewer; A2 |
| 1d | The mark's places and the dialogs' symbols (IQ-B1 B) | — | reviewer |
| 2 | Artworks: one component, `artwork.*` tokens (the four artworks, the Grassfield hills in four phases and two sets), the time-of-day rule (IQ-W1 C), the Settings > Wallpaper "Grassfield" section and its Time of Day / Automatic / Light / Dark choice, the Settings > Appearance thumbnail, A2 runs at every phase, the desktop following the appearance (ID-1, ID-14; IQ-W1 C, IQ-W2 C's artworks). Nothing in `shell/security`; the lock's output unchanged: `WallpaperArt` without a parameter keeps today's drawing, so `LockView.qml` (`:80`) is not edited before step 4a (review of ed21d46) | `shell/desktop` merged (today `WallpaperArt.qml` passes no parameter, so the desktop cannot show the choice before) | reviewer; F1 shots |
| 3 | The wallpaper's first frame from the cache, the ground on Hyprland and the wallpaper window, wallpaper `no_anim`, a hotplugged output's wallpaper, the measurement (ID-2 to ID-4, ID-15's wallpaper part, ID-16). Nothing in `shell/security` | `shell/desktop` merged | reviewer |
| 4a | Lock, the still and the data: the user's wallpaper (ADR-0016 W8), the preloaded still, the scrim (IQ-W4), the surface colour on the ground and on a hotplugged output (ID-2, ID-15), avatar and name once, the clock on resume (ID-7) | step 3; `shell/desktop` merged (LockView imports `qs.desktop`) | **opus security review**, L1 to L5 |
| 4b | Lock, the motion: the fades and the `releasing` state (IQ-T2) | step 4a | **opus security review**, L1 to L5 |
| 5 | Idle, saver and display-off order (ID-8, IQ-T4 A); the red-screen delay, black meanwhile (IQ-T5 A; the nested pass shows only black during the delay) | step 4b | **opus security review** |
| 6 | Session entrance: the ready latch, menu bar, Dock and icons together (ID-20), the menu bar's auto-hide at rest (ID-6), settings first (ID-5), P5 with the wallpaper | `shell/menubar`, `shell/dock`, `shell/desktop`, Appearance.qml merged | reviewer; P5 owner logins |
| 7 | Exit: the countdown (ID-21), the exit cover (ID-10) | — | reviewer |
| 2c | Photographs (IQ-W2 C): first the list (thumbnail, source, licence) to the owner for the legal call; then the files, their `docs/legal` entries, the helper path, the package weight in the pull request | the owner's legal call on the list | reviewer; legal rows |
| 8 | App icons (IQ-B5 C): own icons for Store, Activity Monitor and the Apps tile on one grammar; the two new drawings to the owner's legal call first | `apps/store`, `apps/activity` merged | reviewer; legal row |
| 9 | The moving variant (IQ-W3 A, in 1.0): off by default, also a screen saver kind in `shell/saver`; P1 and P3 measured with it on before the merge request, over budget blocks it. Revised by the integrator (review of e067f26f, P1 over budget): it moves on the lock screen only and comes to rest as the desktop appears, still on the desktop; this puts display code in `shell/security/lock` (the review of 6c310a8 had kept it out) | step 2 | reviewer; **opus security review** (the lock); P1, P3 |
| 10 | Login and boot themes (IQ-L1 C): their own ADR first; SDDM theme in the lock's layout; Plymouth theme with the mark only with the owner's explicit go-ahead inside that ADR (outside master-prompt §4's allowance; plymouthd runs as root in the boot image); a tested fallback to the text disk-password prompt; every root step an owner command | steps 4a, 4b and 5 (the last identity step) | **opus security review**; owner runs |

## Not verified, assumptions, unknowns
- **NOT VERIFIED:** every proposal's rendering in Grassfield (no nested session in this container); the mockups were
  rendered in the container's Chromium only to check the drawings. Every runtime visual claim marked [inference] in the
  audit waits for the integrator's nested pass.
- **ASSUMPTION (macOS, from memory):** the lock screen shows the wallpaper sharp; at login the wallpaper comes first,
  then the menu bar and Dock; auto-hidden bars start hidden; the restart, shut down and log out confirmations count
  down 60 s; Settings offers "Automatic / Light / Dark" for dynamic wallpapers; the lock fades in and out. The owner's
  references have no capture of any of these (`docs/testing/f1-reference-gaps.md:317-321`).
- **VERIFY on Hyprland 0.56.2:** changing `background_color` at run time (ID-2); whether a session lock is confirmed
  while the displays are off (IQ-T4 A with a delay). `misc:lockdead_screen_delay` exists (the integrator's check, review
  of b44d17e); the owner chose IQ-T5 A, so step 5's nested pass shows that only black is drawn during the delay.
- **NOT VERIFIED (step 1c, nested pass):** the accent row, the green tiles' white glyphs and the brand-green tile of
  General > About in the session (offscreen Qt 6.10 draws no `Icon` here); a GTK app with the Green accent (the pinned
  thin marks); the shell's surfaces with the Green accent (menu highlights, focus rings falling back to the text colour).
- **NOT VERIFIED (step 1b, nested pass):** About This Computer in the session: the window's look and size, the mark
  in the brand green (the container's offscreen Qt 6.10 renders no `Icon`: MultiEffect draws nothing there), the shell
  bringing an open window forward. That rests on Hyprland's window data carrying `xdgTag`, which
  `tests/compositor/client_chrome.sh` already reads in the nested session. The single instance (review of ce69dc6): not
  built or run in this container (no Qt development files); the nested pass checks Settings… and a section link with
  Settings open, More Info… with Settings open on another pane, two quick About requests, and the window coming forward
  without a token from the shell (`misc:focus_on_activate` is on). ASSUMPTION (macOS, from memory): About This Mac has no
  title on its bar and only its close light enabled.
- **VERIFY on the owner's machine:** that Arch's tzdata installs `zone1970.tab`, `zone.tab` and `tzdata.zi` under
  `/usr/share/zoneinfo` (they are in this container; IQ-W1 C reads them, and falls back to the fixed hours without
  them).
- **UNKNOWN:** the look of Omarchy's boot and disk-password screens on the owner's machine (not readable here).

## Alternatives rejected
- A cover window that hides the desktop until everything is ready: a splash under another name, not macOS (ID-20).
- A blurred snapshot of the desktop on the lock: window content on the lock breaks gate L4.
- Fading the desktop out before engaging the lock: delays the lock (P-5).
- Shipping photographs that resemble Apple's wallpapers, or any Apple asset: §14.
- Recolouring the mark in its file or drawing variants of it: the mark is the owner's; colour is applied at run time
  only, as IQ-B1 decides.
- A new "brand" colour token beside the default accent: the default accent tokens already are the brand green (R5).
- The first drawings of Activity Monitor (a dark tile with a green line graph) and of the Apps tile (a three-by-three
  grid of coloured squares): too close to macOS's own icons for those apps (review of b44d17e); redrawn as a gauge and
  as fanned cards.

## Legal
- New entry E39 in `docs/legal/visual-review.md`: the mockups (made here, CC-BY-SA-4.0; the existing app icons embedded
  from `branding/icons/apps`, CC-BY-SA-4.0; the mark embedded unchanged, all rights reserved). E12, E32 and E33 carry an
  "Update 2026-10-29" pointing here.
- The proposed artworks inherit E32's flag (`distinct`, side-by-side check before release); names included (ID-18).
- The lock and About layouts stay `close` (E2, E12). The proposed Activity Monitor and Apps tile drawings are flagged
  for the owner's legal call: they were redrawn away from macOS's icons for those apps, and no claim is made that they
  are far enough; the owner chose IQ-B5 C, and the drawings go to the owner's legal call before step 8 ships them
  (decided 2026-10-31: both shipped, « Livrer les deux »). No
  lockup (IQ-B2 A). B-5: the owner checked the name "Grassfield" on 2026-10-18, not the logo; the dossier says so (E33,
  Q7, section 7). Photographs (IQ-W2 C): a licence and provenance entry each, and the owner's legal call on the list
  before any ships.

## Evidence
- The audit's spot checks 1 to 13 (`docs/audits/identity-2026-10-29/audit.md`, section 5), each with its command and
  exit status, on main 11c9e69, and the re-check on main e03c859 (its section "After main e03c859").
- `python3 -I docs/audits/identity-2026-10-29/mockups.py` → exit 0, eight SVG files; `xmllint --noout` on them → exit 0;
  `git diff --check origin/main...HEAD` → exit 0; each SVG rendered with Playwright Chromium in the container (scratch
  PNGs, not committed) and inspected.

## Review history
- **Opus review of b44d17e (integrator, 2026-10-29): FAIL, two MAJORs, five MINORs.** 18 claims checked, all exact.
  - MAJOR 1, step 3 changed the lock surface under a normal review (ID-2, ID-15): the lock surface's colour and a
    hotplugged output's lock surface move to step 4a, under the opus security review; step 3 touches nothing in
    `shell/security`.
  - MAJOR 2, the proposed Activity Monitor and Apps tile icons looked like macOS's: both redrawn (a gauge on a light
    tile; three fanned cards), the "less resemblance" claim removed, E39 flags them for the owner's legal call.
  - MINOR 3, trailing spaces in `b4-app-icons.svg`: `mockups.py` now strips the embedded icons' whitespace and every
    line it writes; `git diff --check` exits 0.
  - MINOR 4, step 2a could not show the artwork choice before `shell/desktop` merges, and the lock draws the artwork:
    step 2 now waits for that merge and keeps the lock's drawing unchanged until step 4a.
  - MINOR 5, IQ-B3 omitted the Settings tiles in the pickable Green: named in section 3 and in the question.
  - MINOR 6, ID-9 reversed H10: now the owner question IQ-T5.
  - MINOR 7, steps 1 and 4 too big: step 1 split into 1a (`DevicePicture` into `Grassfield.Ui`) to 1d, step 4 into 4a
    (the still and the data) and 4b (the fades and `releasing`).
  - Questions: IQ-W3 now recommends B for 1.0; IQ-B1 carries the mark's rules; IQ-B3 names the tiles and goes with
    ADR-0039's Q4 (answered as D-Q4); IQ-B5 now recommends C, the closest to the owner's rule of 2026-10-23; IQ-B4,
    IQ-T1 and IQ-T3 are decided under the macOS model (ID-19 to ID-21); IQ-T5 added.
  - Overlaps with ADR-0039: the section "Coordination with ADR-0039", one owner per overlap, as ADR-0039 lists them.
  - Main e03c859 merged in: the startup-settle fix (8b5efac) already makes the Dock and the desktop icons appear once;
    the audit records it, and ID-5 and ID-6 now cover the menu bar and the wallpaper only.
- **Opus re-review of ed21d46 (integrator, 2026-10-29): FAIL, one MAJOR, one MINOR, two NITs.** Both earlier MAJORs and
  the earlier MINORs fixed (step 2 in part).
  - MAJOR 1, IQ-T4 A was "stricter than today" only on battery: following display-off alone moves the AC default from
    5 to 10 min and never locks with display-off Never and the saver off. Option A now keeps the inactivity limit as the
    ceiling (whichever comes first), so it is never later than today; the question states the defaults and why the
    display-off-only form is not offered; the recommendation, re-checked, stays A.
  - MINOR 2, step 2 could have edited `LockView.qml` under a normal review: step 2 now says "nothing in
    `shell/security`; the lock's output unchanged" (`WallpaperArt` without a parameter keeps today's drawing).
  - NIT 3, stale line references in `visual-review.md` after the merge: `MenuBar.qml:870`, the maintainers' project log.
  - NIT 4, an interrupted `releasing` needs a new PAM success: said in section 4.
- **Opus review of 6c310a8 (step 1a, pull request #52; integrator, 2026-10-29): FAIL, one MAJOR, one MINOR, three
  NITs.** The answers table, the conditions and the `DevicePicture` move were confirmed.
  - MAJOR 1, the time-of-day rule read `zone1970.tab` only, so aliased zones (the owner's Europe/Amsterdam, Africa/Douala,
    Stockholm, Oslo, Copenhagen) fell to the fixed hours: the rule now looks up `zone1970.tab`, then `zone.tab`, then
    the linked zone (`tzdata.zi`), and the probe checks Amsterdam, Douala, Stockholm, a link, the polar branch (which now
    runs: Longyearbyen has a `zone.tab` row), UTC, and the new short-day and short-night rules (12 checks; with
    `zone1970.tab` alone, 6 fail: corrected in step 1b, it said 5).
  - MINOR 2, the R12 argument covered SDDM only: Plymouth is now outside today's allowance and needs the owner's explicit
    go-ahead inside the L1 ADR (section 3, step 10).
  - NIT 3, step 9 says "nothing in `shell/security`"; NIT 4, the stale IQ-T5 wording is fixed; NIT 5, commit 135f0ef's
    author: not rewritten (no history rewrite), the later commits are authored as the owner.
- **Opus re-review of 8a75435 (integrator, 2026-10-29): PASS, one NIT** (merged as a5488a6). The NIT, "five checks fail"
  where the first rule (`zone1970.tab` alone) fails Montreal too, is fixed in step 1b: six (section 2 and the line above).
- **Opus review of ce69dc6 (step 1b, pull request #55; integrator, 2026-10-29): PASS on code, four MINORs, two NITs.**
  - MINOR 1, any lock failure kept About from opening, MINOR 3, More Info… opened a second Settings window when Settings
    was open: Settings is one instance per user over the session bus (AM1's pattern), the lock file is gone.
  - MINOR 2, lspci and `pacman -Q` ran on the GUI thread: shared queries; the window waits for hostname1 and lspci within
    the same bound.
  - MINOR 4, the retired `about` popup kind could still map an empty overlay: Popups refuses any kind its Overlay does not
    draw (`shell/services/PopupKinds.js`, held to the Overlay by `tst_popupkinds.qml`, checked on the real Popups by
    `lock_surfaces`).
  - NITs: "Logiciel" in both places; tests for Esc and Ctrl+W, the hidden empty lines and the window lookup
    (`Minimized.hasTag`).
- **Opus re-review of c6cf328 (integrator, 2026-10-30): FAIL, one MAJOR, one MINOR, one NIT.** The four MINORs above
  confirmed fixed.
  - MAJOR 1, a second launch gave up after 2 s and opened its own Settings while the first was still starting (3.7 to
    7.7 s under load): the hand-over is Activity Monitor's `claimOrHandOver` (up to 25 s; a launch leaves whatever the
    answer and runs only when the name has no owner left). Reproduced with the real binary and a Settings window that takes
    5 s to start: the old hand-over left two instances, the new one one.
  - MINOR 2, nothing tested the single instance: `tests/unit/settings/tst_settingsinstance.cpp` (the name and its suffix,
    the cleaning, the hand-over on a private dbus-daemon, a dev run beside the owner's), built by `build-direct.sh --tests`.
  - NIT 3, `Backend::query` checks its allow-list only in dev: About's commands go through `Backend::readOnlyQuery`, which
    checks it in every session (`tst_backend.cpp`).
- **Opus re-review of 85c2c10 (integrator, 2026-10-30): PASS** (6 races on a private bus at load 8 to 13.5, no second
  instance; a frozen Settings bounds a launch at 25 s per attempt). A MINOR left for a follow-up: a Settings that dies while
  a launch waits on it answers NoReply, not "no owner", so that click was lost; the launch now retries whenever the name has
  no owner after any error (`tst_settingsinstance.cpp`: the owner, this test binary run again, killed during the call).
- **Nested pass of 85c2c10 (integrator, 2026-10-30): single instance PASS; FAIL scenario 6, one MINOR.**
  - Scenario 6, the pointer resting on About's disabled (grey) zoom light opened the full tiling popover: the plugin posted
    `tile-hover` for every `org.grassfield.*` window with app-drawn lights. A window of fixed size (minimum = maximum on both
    axes, core `tiling::fixedSize`) now posts no `tile-hover` from its zoom light and `tile_popover` (Super+Ctrl+L) is
    refused for it, on hover or click; the `hyprctl grassfield-tiling` reply lists such windows (`fixed`), and the Window
    menu greys their Zoom, Enter Full Screen, Full Screen Tile and tiling items (Unzoom and Exit Full Screen stay); the
    tiling keys refused them already (TL9). Tests: `TilingFixed` (core), `tst_windowtiling.qml`, `tst_appmenumodel.qml`
    and the nested case `fixed` of `tests/compositor/tiling.sh` (About's hover and click: no event, no popup, its box kept).
  - MINOR, in French About's processor wrapped to three lines: the window shows the processor's name alone (About This Mac
    names the chip alone; the French thread count alone cut the model), shortened (`SysInfo.cpuShortName`: no "(R)",
    "(TM)", "CPU", clock, generation prefix, integrated graphics or trailing "Processor"), on one line cut in the middle,
    the full model name in a tooltip while the pointer rests on it when it was shortened or cut. General > About keeps the
    thread count after the same short name.

- **Opus review of 5391761 (step 1c, pull request #69; integrator, 2026-10-30): FAIL, one MAJOR, two MINORs, NITs.** The
  design held; the nested pass (French, light and dark, the accent row, About, the controls, the Dock and the menu bar in
  Green) was legible.
  - MAJOR 1, the new About test's fake system had `act()` alone: three TypeErrors in the full unit run, which gate Q2
    (`tests/ci/qml_warnings.py`) counts. The fake now has what AboutPage and DevNote read (`queryBus`, `errors`,
    `suppressedNote`); Q2 exits 0 on the full run.
  - MINOR 2, Software Update's Grassfield release row drew the mark's tile in the pickable Green: it uses the brand green.
  - MINOR 3, text drawn in the accent colour fell to 2.1-2.5:1 with the light Green (yellow already had it). The
    integrator's decision, under the owner's rule of 2026-10-27: as macOS, a light accent's text is drawn darker. A role,
    `colors.accentInk`: `color.accentInkLight` gives yellow `#816500`, green `#467427` and pink `#BD2F6C` (pink was 4.34:1
    under a rimmed capsule; pink's entry was removed on 2026-11-03, see the amendment), each the lightest shade of its accent with 4.5:1 on an app window; every other accent and the
    dark appearance draw in the accent itself. Two A2 roles: on an app window (4.5:1, every accent, both appearances) and
    on glass (exempt when this was written; the exemption ended on 2026-11-08, see the amendment below). Ten texts and glyphs moved to it (the widgets' weekday, a Control Center checkmark, the alert glyph, Files'
    Show All and Show More and sidebar glyphs, the Store button label and its sidebar and category glyphs); a test fails
    when a text or glyph reads the bare accent.
  - NITs: ADR-0039's knob wording and the comments of `RadioRow.qml` and `StoragePage.qml` now name green beside yellow;
    main merged (STATE only).

## Consequences
- The owner's answers of 2026-10-29 decide steps 1c to 10 (section "Owner decisions (2026-10-29)"); step 1 starts first.
- ADR-0016 is extended, not replaced: its §6 (the lock still) is step 4a here; its §10 P5 promise is kept by ID-3.
- ADR-0014 and ADR-0017: under IQ-B5 C (decided) the pack keeps Files, Settings and Preview; own icons for Store,
  Activity Monitor and the Apps tile.
- A new ADR for the login and boot themes (IQ-L1 C) before step 10.
- ADR-0020 gains rows for the new keys and the wallpaper state when steps 2, 3 and 5 write them.
- Security: steps 4a, 4b and 5 are security-module changes (R12), each with an opus security review.

## Amendment 2026-11-03 pink needs no accent ink

The pink entry of `color.accentInkLight` (#BD2F6C) is removed. It existed because pink fell to 4.34:1 under the toolbar
capsule's grey fill. Since the refinement batch (ADR-0024 amendment 2026-11-03) the toolbar capsule is white (it lightens
the window) and the sidebar search field, a flat grey, is not a ground for accent text; the A2 role "text and glyphs in the
accent colour on an app window" now uses the `window-pane` backdrop (the window and the sidebar, bare and under the capsule),
where plain light pink holds 4.5:1 (tests/visual/test_contrast_tokens.py, `test_accent_ink_only_where_needed`). Yellow and
green keep their inks. Pink accent text is therefore the pink accent itself in both appearances.

The floating sidebar (ADR-0024 amendment 2026-11-03, second one) adds a second reason: its light fill goes from 15 to 6 levels
under the window (#F7F6F3), a lighter ground, so plain pink holds 4.92:1 on it at the worst (the bare sidebar, since the capsules turned white).

## Amendment 2026-11-08 accent text on glass holds 4.5:1; the A2 exemption is gone

Audit defect R7-A11Y-01: the A2 role "text and glyphs in the accent colour on material" was exempt (no accent held 4.5:1 over
the worst wallpaper). It is not any more. Text and glyphs of the shell's glass (the widgets' weekday, a Control Center
checkmark, an alert glyph) read `colors.accentGlass`: `Accent.glassInk` mixes the accent ink toward the text colour by
`glass.accentInkMixDark` (0.76) or `glass.accentInkMixLight` (0.58), as macOS draws accent text on vibrancy with a
legibility-adjusted accent. App-window text keeps `colors.accentInk`.
- The first version was tested on the default material (tint 0.85 or 0.82). The shell's glass is thinner: `GlassTint.alpha`
  protects the text and the secondary text only (0.79 in the light appearance over a window). Gate A2 now uses the shell's
  real model (every glass class, the worst-case and the known backdrops, bare and under the row and tile fills, from the
  same tokens and formulas as the QML). Under it the light yellow and green were 4.43:1 and the light pink 4.53:1 at 0.55;
  0.58 gives 4.58:1 worst (light yellow); the dark red is 4.59:1 at 0.76.
- The role lists its real sites (`readers` in contrast-roles.json); a test fails when shell glass text reads `accentInk` or
  app-window text reads `accentGlass`. The 18 colours are pinned in `tst_accent.qml` and in the A2 test.
- In the dark appearance the variant is a pale shade (OKLCH hue within 12 degrees of the accent's, chroma 0.03 to 0.05);
  a more saturated variant would need a gamut-mapped OKLCH mix and is not done.
