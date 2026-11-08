# User-reported regressions

The ledger of failures that people using Grassfield reported (the owner, beta testers), ADR-0053 D-5. One entry per reported
failure, under a stable ID that never changes and is never reused: `URR-NNN` (three digits, in the order the reports arrive).
Commits, tests and STATE.md cite the ID.

**A source fix is not a shipped fix.** An entry stays open until a released version carries the fix and the reporter's case
was verified on that version. "Fixed on main" is a status, not the end.

How to fill an entry:
- Reported: the date, who (a role, never a name: "owner", "beta tester"), and the version they ran (`Grassfield version` of
  their diagnostic report, `grassfield-report`; never "latest").
- Reproduction: the steps that show the failure, on which hardware or setup, and how often. Attach nothing private here:
  the report itself stays with the person or in the private channel it came through.
- Cause: what was wrong, with the commit that introduced it when known.
- Fix: the commit(s) and the test that now fails without the fix (a regression test is required; name its file).
- Verification: how the fix was seen to work (the test, and the reporter's own check on the shipped version when possible),
  with the evidence reference (gate run report, screenshot, log line).
- First shipped version: the first released version (`VERSION` of a published package) that carries the fix; empty until
  then.
- Severity (1.0 threshold): `blocker` (data loss, a session that cannot be used, a security failure), `high` (a main
  function broken, or a frequent visible failure), `medium` (a workaround exists) or `low` (cosmetic, or a request where
  nothing is broken), judged by the impact on the person and counted against the owner's 1.0 threshold of 2026-11-08 (no
  blocker and no high-severity defect open).
- Status: `open` (reported, not fixed) · `fixed in source` (merged; not released, or released but not yet verified
  by the reporter, the first shipped version then filled) · `shipped` (released, verified) ·
  `accepted limitation (owner, DATE)` (the owner decided on DATE to ship with it as a known limit) · `not reproduced`
  (closed without a fix, with the reason) · `duplicate of URR-NNN`.

## Entries

Template:

```markdown
### URR-001: <one line: what the reporter saw>
- Status: open
- Severity (1.0 threshold): <blocker | high | medium | low>
- Reported: YYYY-MM-DD, <role>, Grassfield <version> (diagnostic report: yes/no)
- Reproduction: <steps; setup; frequency>
- Cause: <what was wrong; introduced by <commit> if known>
- Fix: <commit(s)>; regression test: <file>
- Verification: <how, evidence reference>
- First shipped version: <version, or empty>
```

Seeded on 2026-11-08 from the owner's reports of 2026-11-02 to 2026-11-07 (1.0.0rc1-16 to 1.0.0-rc6).
Earlier reports are not entered.
Versions written `1.0.0rc1-N` are local test packages; 1.0.0-rc2 to 1.0.0-rc7 are published on the beta channel.
A fix is in a version when its merge commit is an ancestor of the tag:
`git merge-base --is-ancestor <commit> v<version>`.
By 2026-11-08 the owner had verified no fix on a published version, so no entry is `shipped` yet.
None of these reports came with a diagnostic report.

### URR-001: The secret sheets never appeared: grassfield-prompter failed at every start
- Status: fixed in source
- Severity (1.0 threshold): high
- Reported: 2026-11-02, owner (L2 check on the owner's laptop), Grassfield 1.0.0rc1-16 (diagnostic report: no)
- Reproduction: log in; `grassfield-prompter` and `grassfield-secrets-handover` fail with status 218/CAPABILITIES; every
  start.
- Cause:
  - Both user units set `CapabilityBoundingSet=` without an option that gives them a user namespace.
  - A user manager cannot drop a bounding set outside a user namespace, so neither unit started.
  - No secret sheet (network passwords, keyring, Bluetooth pairing) could appear.
- Fix: d3a1fbc4 (merge 6bb39e55); regression test: tests/shell/session_services.sh
- Verification: tests: tests/shell/session_services.sh; the prompter registered on the owner's laptop with 1.0.0rc1-21
  (journal, read-only); reporter's check pending
- First shipped version: 1.0.0-rc2

### URR-002: Settings' sidebar kept its scroll bar visible while nothing moved
- Status: fixed in source
- Severity (1.0 threshold): low
- Reported: 2026-11-02, owner, Grassfield 1.0.0rc1-16 (diagnostic report: no)
- Reproduction: open Settings; the sidebar's scroll bar stays at half opacity over a still view; always.
- Cause: the shared ScrollBar kept its thumb at opacity 0.5 while the view was still.
- Fix: 0e2cd87b (merge 46dcae04); regression test: tests/unit/tst_controlsmisc.qml
- Verification: tests: tests/unit/tst_controlsmisc.qml; reporter's check pending
- First shipped version: 1.0.0-rc2

### URR-003: Preview's window title started under the traffic lights
- Status: fixed in source
- Severity (1.0 threshold): low
- Reported: 2026-11-02, owner, Grassfield 1.0.0rc1-16 (diagnostic report: no)
- Reproduction: open one picture in Preview (no sidebar toggle in the toolbar); the title starts under the lights.
- Cause: the title made room for the traffic lights only through the sidebar toggle.
- Fix: 4a967b80 (merge 2b7a00b3); regression test: tests/unit/tst_previewviewer.qml
- Verification: tests: tests/unit/tst_previewviewer.qml; reporter's check pending
- First shipped version: 1.0.0-rc2

### URR-004: Tinted Dock icons showed a coloured tile inside a pale plate at 125 % scale
- Status: fixed in source
- Severity (1.0 threshold): low
- Reported: 2026-11-02, owner, Grassfield 1.0.0rc1-16 (diagnostic report: no)
- Reproduction: tinted icons, a display at scale 1.25; the Dock's icons show a coloured tile inside a pale plate;
  always.
- Cause: `Canvas.drawImage("image://icon/…")` paints at about half size on a fractional output, so the tile check read
  the icon as no tile and drew a plate around it.
- Fix: 84a6f7d1, f8f60d40 (merge f48059e1); regression test: tests/unit/tst_icontile.qml, tests/shell/icontile_hidpi.sh
- Verification: tests: tests/unit/tst_icontile.qml, tests/shell/icontile_hidpi.sh; reporter's check pending
- First shipped version: 1.0.0-rc2

### URR-005: Every photograph in Settings > Wallpaper said "This path can't be used"
- Status: fixed in source
- Severity (1.0 threshold): medium
- Reported: 2026-11-03, owner, Grassfield 1.0.0rc1-18 (diagnostic report: no)
- Reproduction: Settings > Wallpaper, choose any photograph file; the pane refuses it; always.
- Cause:
  - `WallpaperFeed.startPrepare` had typed string parameters, and the file callers passed the path alone.
  - The missing fit arrived as the text "undefined", which the preparation refused as an invalid path.
- Fix: fc54a82f (merge 10785ffd); regression test: tests/unit/tst_wallpaper.qml
- Verification: tests: tests/unit/tst_wallpaper.qml; reporter's check pending
- First shipped version: 1.0.0-rc2

### URR-006: A right-click on the desktop of a second display opened no menu
- Status: fixed in source
- Severity (1.0 threshold): medium
- Reported: 2026-11-04, owner, Grassfield 1.0.0rc1-22 (diagnostic report: no)
- Reproduction: desktop PC with several displays; right-click the empty desktop of a display without icons; nothing
  opens.
- Cause: only the display with the desktop icons had a desktop surface.
- Fix: 4cedab88, 6c6f00ac (merge d640ef3a), then 5768c43c (no display name read after an unplug); regression test:
  tests/unit/tst_desktopicons.qml, tests/unit/tst_iconmenu.qml, tests/visual/desktop-menu-displays.sh
- Verification: tests: tests/unit/tst_desktopicons.qml, tests/unit/tst_iconmenu.qml,
  tests/visual/desktop-menu-displays.sh; reporter's check pending
- First shipped version: 1.0.0-rc3

### URR-007: Desktop icons were hidden under the wallpaper on a display plugged in later
- Status: fixed in source
- Severity (1.0 threshold): medium
- Reported: 2026-11-04, owner, Grassfield 1.0.0rc1-22 (diagnostic report: no)
- Reproduction: desktop PC; plug a display in while the session runs; the wallpaper covers the desktop icons drawn
  there.
- Cause: the icons and the wallpaper share a layer; on a display plugged in later the wallpaper mapped after the icons.
- Fix: c5b944ee, 0d7cf8bc (merge d640ef3a): layer rules stack the icons above the wallpaper; regression test:
  tests/visual/desktop-hotplug.sh
- Verification: tests: tests/visual/desktop-hotplug.sh (nested, hot-plugged displays at 1.25); reporter's check pending
- First shipped version: 1.0.0-rc3

### URR-008: A video opened in Preview did not start playing
- Status: fixed in source
- Severity (1.0 threshold): low
- Reported: 2026-11-04, owner, Grassfield 1.0.0rc1-22 (diagnostic report: no)
- Reproduction: open a video in the Preview window; it stays stopped until Play is pressed; always.
- Cause: autoplay was set for Glance only, not for the Preview window.
- Fix: 30c84114 (merge d640ef3a); regression test: tests/unit/tst_previewviewer.qml
- Verification: tests: tests/unit/tst_previewviewer.qml; reporter's check pending
- First shipped version: 1.0.0-rc3

### URR-009: A request for "magnetism" (snapping) of windows and desktop icons
- Status: not reproduced
- Severity (1.0 threshold): low
- Reported: 2026-11-04, owner, Grassfield 1.0.0rc1-22 (diagnostic report: no)
- Reproduction: none recorded.
- Cause: icon snapping and window snapping are on by default; the owner was asked which setting was meant; no answer is
  recorded.
- Fix: none
- Verification: none
- First shipped version:

### URR-010: Files did not list the computer's other disks and partitions
- Status: fixed in source
- Severity (1.0 threshold): high
- Reported: 2026-11-04, owner, Grassfield 1.0.0rc1-22 (diagnostic report: no)
- Reproduction: desktop PC with several internal disks; Files' sidebar does not show them; Files cannot open or mount
  them.
- Cause: Locations did not list the internal drives and partitions that udisks2 knows.
- Fix: ad50b788 (merge d05f0ca9): every openable filesystem, system and hidden partitions left out, mounted on click;
  regression test: tests/unit/files/tst_volumelogic.cpp, tests/unit/files/tst_diskprobe.cpp
- Verification: tests: tests/unit/files/tst_volumelogic.cpp, tests/unit/files/tst_diskprobe.cpp; reporter's check
  pending
- First shipped version: 1.0.0-rc3

### URR-011: The mouse's Back and Forward buttons did nothing in Files
- Status: fixed in source
- Severity (1.0 threshold): medium
- Reported: 2026-11-04, owner, Grassfield 1.0.0rc1-22 (diagnostic report: no)
- Reproduction: desktop PC with an external mouse; press its Back or Forward button in a Files window; nothing happens.
- Cause: Files handled neither the mouse's Back and Forward buttons nor the XF86Back and XF86Forward keys.
- Fix: 0016304f (merge d05f0ca9); regression test: tests/unit/tst_fileshistorybuttons.qml
- Verification: tests: tests/unit/tst_fileshistorybuttons.qml; reporter's check pending
- First shipped version: 1.0.0-rc3

### URR-012: Items could not be dragged out of Files' Columns view
- Status: fixed in source
- Severity (1.0 threshold): medium
- Reported: 2026-11-04, owner, Grassfield 1.0.0rc1-22 (diagnostic report: no)
- Reproduction: Files in Columns view; drag an item to another folder or app; no drag starts; always.
- Cause: the Columns view had drop targets but no drag source.
- Fix: 6513fc90, 1621d2f1 (merge 3684e39b); regression test: tests/unit/tst_filescolumns.qml
- Verification: tests: tests/unit/tst_filescolumns.qml; 10 Esc-cancelled drags in nested at 1.25 (merge 3684e39b);
  reporter's check pending
- First shipped version: 1.0.0-rc3

### URR-013: The Copy window showed no progress for a paste
- Status: fixed in source
- Severity (1.0 threshold): medium
- Reported: 2026-11-04, owner, Grassfield 1.0.0rc1-22 (diagnostic report: no)
- Reproduction: copy large items and paste them in Files; the Copy window shows no amounts or time left.
- Cause: KIO's PasteJob forwards no amounts, and the Copy window followed it instead of the copy job it runs.
- Fix: 27065257, 7a954de8 (merge 3684e39b); regression test: tests/unit/files/tst_fileops.cpp,
  tests/unit/files/tst_filelogic.cpp
- Verification: tests: tests/unit/files/tst_fileops.cpp, tests/unit/files/tst_filelogic.cpp; reporter's check pending
- First shipped version: 1.0.0-rc3

### URR-014: No way to choose the main display
- Status: fixed in source
- Severity (1.0 threshold): medium
- Reported: 2026-11-04, owner, Grassfield 1.0.0rc1-22 (diagnostic report: no)
- Reproduction: desktop PC with several displays; nothing chooses the display that holds the Dock, the desktop icons and
  the banners.
- Cause:
  - 1.0.0rc1-22 had no main display: the Dock started on the focused display, the icons went to the first display and
    the banners to the focused one (ADR-0044).
  - After the first fix (1.0.0-rc3), the main display's "Use as" pop-up offered only "Main display", sat below the
    resolution and brightness, and Arrange… could not move the menu bar (URR-023).
- Fix:
  - 73c1f742, 00f65ee4, 7c936255, 28fdbfbb (merge b590e54e, ADR-0044): "Use as" per display; the Dock, icons and banners
    on the main display.
  - 0874f165 (PR #10, merge f85396e8, ADR-0044 A-2): "Use as" first on every display with both choices; the menu bar
    dragged to another display in Arrange….
  - regression test: tests/unit/tst_displayrole.qml, tests/unit/tst_settingsdisplays.qml,
    tests/unit/tst_dockgeometry.qml
- Verification: tests: tests/unit/tst_displayrole.qml, tests/unit/tst_settingsdisplays.qml,
  tests/unit/tst_dockgeometry.qml; the reporter's check failed on 1.0.0-rc6 (URR-023); reporter's check on 1.0.0-rc7
  pending
- First shipped version: 1.0.0-rc7 (1.0.0-rc3 carried the first fix, which did not reach the reporter's case)

### URR-015: No way to set a wallpaper per display
- Status: fixed in source
- Severity (1.0 threshold): low
- Reported: 2026-11-04, owner, Grassfield 1.0.0rc1-22 (diagnostic report: no)
- Reproduction: desktop PC with several displays; Settings > Wallpaper applies one picture to every display.
- Cause: the Wallpaper pane had no display choice.
- Fix: 7c936255 (merge b590e54e): the pane's display pop-up,
  `grassfield-settings --section=wallpaper --display=<output>`, and the desktop's Change Wallpaper… opening on the
  display right-clicked; regression test: tests/unit/settings/tst_settingsinstance.cpp, tests/visual/main-display.sh
- Verification: tests: tests/unit/settings/tst_settingsinstance.cpp, tests/visual/main-display.sh (nested, two outputs
  at 1.25); reporter's check pending
- First shipped version: 1.0.0-rc3

### URR-016: No Input menu, and Ctrl+Space did not switch every keyboard's layout
- Status: fixed in source
- Severity (1.0 threshold): medium
- Reported: 2026-11-04, owner, Grassfield 1.0.0rc1-22 (diagnostic report: no)
- Reproduction: desktop PC with two keyboard layouts; the menu bar shows no input source; Ctrl+Space switches only the
  keyboard being typed on.
- Cause:
  - Ctrl+Space came from the xkb option `grp:ctrl_space_toggle`, which switches only the keyboard being typed on.
  - The menu bar had no Input menu.
- Fix: 24b5cd7d, 086bc32e, c2859937 (merge cc6a2ee3): the Input menu, Ctrl+Space and Ctrl+Option+Space for every
  keyboard, also at the lock screen; regression test: tests/unit/tst_inputsource.qml, tests/shell/bindings_forward.sh
- Verification: tests: tests/unit/tst_inputsource.qml, tests/shell/bindings_forward.sh; reporter's check pending
- First shipped version: 1.0.0-rc3

### URR-017: A click on the frontmost app's Dock tile did nothing (request: minimize the app)
- Status: fixed in source
- Severity (1.0 threshold): low
- Reported: 2026-11-04, owner, Grassfield 1.0.0rc1-22 (diagnostic report: no)
- Reproduction: click the Dock tile of the app in front; nothing happens, as on macOS.
- Cause: none; a request for a behaviour macOS does not have.
- Fix: merge c7fd9237: the click minimizes the app's windows on this Desktop into its Dock icon (a Desktop & Dock
  setting, on by default); regression test: tests/unit/tst_docklaunch.qml
- Verification: tests: tests/unit/tst_docklaunch.qml; reporter's check pending
- First shipped version: 1.0.0-rc3

### URR-018: GTK header bars showed no traffic lights, and Firefox showed two title bars
- Status: fixed in source
- Severity (1.0 threshold): medium
- Reported: 2026-11-04, owner (with a screenshot), Grassfield 1.0.0rc1-22 (diagnostic report: no)
- Reproduction: open a GTK app with a header bar; its title buttons are not traffic lights; Firefox shows the plugin's
  title bar above its own.
- Cause:
  - The generated GTK themes did not draw the title buttons as traffic lights.
  - Firefox was not in the client-chrome list, so the plugin added its title bar.
- Fix: d9169e35, f172ecc5, 5de071d9 (merge 265be724); regression test: tests/ci/gtk_themes.py,
  tests/compositor/gtk_lights.sh, tests/shell/client_chrome_rules.sh
- Verification: tests: tests/ci/gtk_themes.py, tests/compositor/gtk_lights.sh, tests/shell/client_chrome_rules.sh;
  Firefox's own buttons not verified (accepted as a known limit by the owner on 2026-11-08); reporter's check pending
- First shipped version: 1.0.0-rc3

### URR-019: No Energy settings on a computer without a battery
- Status: fixed in source
- Severity (1.0 threshold): medium
- Reported: 2026-11-04, owner, Grassfield 1.0.0rc1-22 (diagnostic report: no)
- Reproduction: desktop PC without a battery; Settings has no way to set the power mode or to keep the computer awake.
- Cause:
  - Settings had no Energy pane without a battery, and nothing offered power-profiles-daemon's modes.
  - What looked like sleep was most likely the displays turning off and the session locking (ADR-0010 amendment of
    2026-11-04).
- Fix: ff698700, fc94b11f, cbe96629, 71e62a15 (merge 3f920ee7); regression test: tests/unit/tst_settingspower.qml,
  tests/security/tst_idlemodel.qml
- Verification: tests: tests/unit/tst_settingspower.qml, tests/security/tst_idlemodel.qml; reporter's check pending
- First shipped version: 1.0.0-rc3

### URR-020: No way to uninstall an app
- Status: fixed in source
- Severity (1.0 threshold): high
- Reported: 2026-11-04, owner, Grassfield 1.0.0rc1-22 (diagnostic report: no)
- Reproduction: try to remove an installed app from the launcher or Files; nothing offers it.
- Cause:
  - The Store could remove apps, but the launcher and Files offered no way to reach it (ADR-0046).
  - The Store helper's deny list kept Omarchy's optional preinstalls.
- Fix: 65b8e012, 0280df31, 36084bba, 266545b3 (merge 4bbb77d7, ADR-0046); regression test: tests/unit/tst_uninstall.qml,
  tests/unit/store/tst_removal.cpp, tests/shell/store_helper_e2e.sh
- Verification: tests: tests/unit/tst_uninstall.qml, tests/unit/store/tst_removal.cpp, tests/shell/store_helper_e2e.sh;
  reporter's check pending
- First shipped version: 1.0.0-rc3

### URR-021: External displays sometimes stayed black after sleep until replugged
- Status: fixed in source
- Severity (1.0 threshold): high
- Reported: 2026-11-07, owner, Grassfield 1.0.0-rc6 (diagnostic report: no)
- Reproduction: desktop PC with several displays; sleep, then wake; some external displays stay black; sometimes.
- Cause:
  - A monitor probed while asleep answers without video modes; Hyprland 0.56.2 brings it up at 0x0 and stops after three
    retries.
  - Omarchy's session recovers it (omarchy-hyprland-monitor-watch); Grassfield's autostart did not port that recovery.
- Fix: 70dea8b0 (PR #10, merge f85396e8): the shell reloads the configuration while a display has no mode (after 3 s,
  doubling, at most 60 s); regression test: tests/shell/displays_modeless.sh, tests/unit/tst_displaysfile.qml
  - not fixed: a display too slow to wake can stay black while Hyprland marks it on (docs/specs/settings.md).
- Verification: tests: tests/shell/displays_modeless.sh, tests/unit/tst_displaysfile.qml; reporter's check pending
- First shipped version: 1.0.0-rc7

### URR-022: Waking from sleep was very slow
- Status: fixed in source
- Severity (1.0 threshold): medium
- Reported: 2026-11-07, owner, Grassfield 1.0.0-rc6 (diagnostic report: no)
- Reproduction: desktop PC with several displays; wake from sleep; the displays light late; the time was not measured.
- Cause: the displays that the lock screen turned off before sleep stayed off after the resume until a second input; the
  key that wakes the computer is usually consumed by the wake (supported by the code, not measured).
- Fix: c94e3195, 44412d23 (PR #10, merge f85396e8): a resume lights the lock screen after 1.5 s, display only;
  regression test: tests/security/tst_idlemodel.qml, tests/security/lock_privacy.sh
- Verification: tests: tests/security/tst_idlemodel.qml, tests/security/lock_privacy.sh (nested, display-off case);
  reporter's check pending
- First shipped version: 1.0.0-rc7

### URR-023: No way to set the main display (reported again on 1.0.0-rc6)
- Status: duplicate of URR-014
- Severity (1.0 threshold): medium
- Reported: 2026-11-07, owner, Grassfield 1.0.0-rc6 (diagnostic report: no)
- Reproduction: desktop PC with several displays; Settings > Displays shows the main display, whose "Use as" pop-up
  holds only "Main display".
- Cause: see URR-014.
- Fix: 0874f165 (PR #10, merge f85396e8); see URR-014.
- Verification: see URR-014.
- First shipped version: 1.0.0-rc7

### URR-024: The scale set in Settings was not applied (stayed at 120 % while set to 100 %)
- Status: fixed in source
- Severity (1.0 threshold): medium
- Reported: 2026-11-07, owner, Grassfield 1.0.0-rc6 (diagnostic report: no)
- Reproduction: development laptop with a 1920x1080 panel at about 144 ppi; Settings > Displays offers no 100 %; the
  display stays at scale 1.25.
- Cause:
  - The scale choices spanned around Hyprland's default scale, 1.5 for this panel, so the most space offered was 1.25.
  - The native resolution (100 %) was never a choice, and the 1.25 kept earlier stayed.
- Fix: e0a6e922, ea078123 (PR #10, merge f85396e8): a display below 150 ppi always offers its native resolution;
  regression test: tests/unit/tst_settingsdisplays.qml
- Verification: tests: tests/unit/tst_settingsdisplays.qml; reporter's check pending
- First shipped version: 1.0.0-rc7

### URR-025: A zoomed window moved to a smaller display overflowed it
- Status: fixed in source
- Severity (1.0 threshold): medium
- Reported: 2026-11-07, owner, Grassfield 1.0.0-rc6 (diagnostic report: no)
- Reproduction: two displays of different sizes; move a filled window to a Desktop of the smaller display; it keeps its
  size and overflows.
- Cause: a window moved to another display's Desktop kept its size; Hyprland bottom-aligned it inside the display.
- Fix: 5e60cf5a, a2a4ea79 (PR #15, merge 23ffea7b): a window that lands on another display fits its work area;
  regression test: compositor/tests/TilingTest.cpp, tests/compositor/display_fit.sh
- Verification: tests: compositor/tests/TilingTest.cpp, tests/compositor/display_fit.sh; reporter's check pending
- First shipped version: 1.0.0-rc7

### URR-026: Dragging a window to the top of the screen to fill it was slow
- Status: fixed in source
- Severity (1.0 threshold): medium
- Reported: 2026-11-07, owner, Grassfield 1.0.0-rc6 (diagnostic report: no)
- Reproduction: drag a window by its title bar up to the menu bar; the window trails the pointer and the fill waits.
- Cause:
  - Each step of the plugin's title bar drag restarted Hyprland's 300 ms move animation.
  - The menu bar waited for the 250 ms preview delay of the side edges.
- Fix: fb211a61, 970eda33 (PR #15, merge 23ffea7b); regression test: compositor/tests/TilingTest.cpp,
  tests/compositor/tiling.sh
- Verification: tests: compositor/tests/TilingTest.cpp, tests/compositor/tiling.sh; reporter's check pending
- First shipped version: 1.0.0-rc7

### URR-027: A window could still end up with its title bar under the menu bar
- Status: fixed in source
- Severity (1.0 threshold): high
- Reported: 2026-11-07, owner, Grassfield 1.0.0-rc6 (diagnostic report: no); reported before on 2026-10-25
- Reproduction: move a large window to a Desktop of another display (Overview, a key) or drop it there by its title bar;
  its title bar sits under the menu bar.
- Cause:
  - Hyprland bottom-aligned a window moved to another display, which put its title bar under the menu bar.
  - Windows placed while the shell's menu bar was away stayed under it when it came back.
- Fix: 5e60cf5a, 346d3037 (PR #15, merge 23ffea7b); regression test: tests/compositor/display_fit.sh
  - not fixed: during Hyprland's own drags (an app's move request, Super+drag) the window passes under the menu bar and
    moves down at the release (docs/specs/compositor.md).
- Verification: tests: tests/compositor/display_fit.sh; reporter's check pending
- First shipped version: 1.0.0-rc7

### URR-028: Chromium, Google Chrome and Firefox showed no traffic lights by default
- Status: fixed in source
- Severity (1.0 threshold): medium
- Reported: 2026-11-07, owner, Grassfield 1.0.0-rc6 (diagnostic report: no)
- Reproduction: open Chromium or Google Chrome in the Grassfield session; the window buttons are not traffic lights.
- Cause:
  - Omarchy's theme switcher writes the machine policy BrowserThemeColor, and its colour theme replaces the GTK
    appearance's window buttons in every profile.
  - Chromium gives new profiles its GTK appearance only on desktops it knows as GNOME-like.
- Fix: cee4a69e, 64debeef (PR #15, merge 23ffea7b) installed zz-grassfield-gtk.json machine-wide: replaced on
  2026-11-08 (owner decisions R7-OMA-01 and R7-FUN-04) by the session-only browser stand-in
  packaging/session-bin/chromium: a new profile is created in the GTK appearance, Omarchy's color.json is hidden from
  the browser in a private mount namespace, nothing is installed in /etc; fb34adcb adds Google Chrome to the
  client-chrome list; regression tests: tests/shell/browser_session.sh, tests/shell/client_chrome_rules.sh
- Verification: tests: tests/shell/browser_session.sh (logic; runtime NOT VERIFIED in the Claude sandbox), the lights
  on screen: tests/compositor/gtk_lights.sh (nested); Firefox not verified (accepted as a known limit by the owner
  on 2026-11-08); reporter's check pending
- First shipped version: 1.0.0-rc7

### URR-029: Chrome with "Use system title bar" lacks window buttons
- Status: accepted limitation (owner, 2026-11-08)
- Severity (1.0 threshold): medium
- Reported: 2026-11-07, owner, Grassfield 1.0.0-rc6 (diagnostic report: no); this case of URR-028 was found in the
  review of PR #15
- Reproduction: in Chromium or Google Chrome, turn on "Use system title bar"; the window shows no title bar buttons.
- Cause: the browsers stay in the client-chrome list, so the plugin draws no title bar; with that option the browser
  draws none either.
- Fix: none; accepted for 1.0 by the owner on 2026-11-08 (workaround: turn the option off)
- Verification: none
- First shipped version:

### URR-030: Tiling did not react to dragging a tab of Chrome's title bar
- Status: open
- Severity (1.0 threshold): medium
- Reported: 2026-11-07, owner, Grassfield 1.0.0-rc6 (diagnostic report: no)
- Reproduction: Chromium or Google Chrome; drag a tab (also the only one) to a screen edge or the menu bar; nothing
  tiles, and the tab comes off into a window that does not follow the pointer.
- Cause: a tab drag is Chromium's own drag and drop, which moves a window only through the `zcr_extended_drag_v1`
  protocol; Hyprland 0.56.2 does not have it.
- Fix: none yet; the empty part of the tab strip uses Hyprland's move and tiles (workaround); the limit is written in
  docs/specs/compositor.md
- Verification: measured in nested with Chromium 155 (PR #15)
- First shipped version:

### URR-031: Telegram and the ArtCraft suite showed two title bars
- Status: fixed in source
- Severity (1.0 threshold): medium
- Reported: 2026-11-07, owner, Grassfield 1.0.0-rc6 (diagnostic report: no)
- Reproduction: open Telegram; the plugin's title bar shows above the app's own.
- Cause: the client-chrome tag came only from a per-app session rule, which named neither Telegram (a Qt frameless
  window) nor the ArtCraft apps.
- Fix: 7734d209, 07d132a9 (PR #15, merge 23ffea7b): the plugin reads the decoration the client negotiated (P9);
  regression test: compositor/tests/ClientChromeTest.cpp, tests/compositor/decorations.sh
- Verification: tests: compositor/tests/ClientChromeTest.cpp, tests/compositor/decorations.sh; the ArtCraft suite not
  verified (its app ids are unknown); reporter's check pending
- First shipped version: 1.0.0-rc7

### URR-032: A Qt frameless window that draws nothing has no title bar
- Status: open
- Severity (1.0 threshold): medium
- Reported: 2026-11-07, owner, Grassfield 1.0.0-rc6 (diagnostic report: no); this case follows from the fix of URR-031
  and was found in the review of PR #15
- Reproduction: a Qt app shows a frameless window that draws no bar of its own; the window has no title bar and no
  traffic lights.
- Cause: P9 reads a client that bound a decoration manager and holds no decoration object (Qt's frameless window) as one
  that draws its own bar, so the plugin draws none.
- Fix: none yet; to fix before 1.0 (owner, 2026-11-08); workaround: Super+drag moves the window
- Verification: none
- First shipped version:

### URR-033: The translucent menu bar was nearly opaque on some displays
- Status: fixed in source
- Severity (1.0 threshold): low
- Reported: 2026-11-07, owner, Grassfield 1.0.0-rc6 (diagnostic report: no)
- Reproduction: "Show menu bar background" on, several displays; the band is glass over a display without windows and
  nearly opaque over one with a window.
- Cause: the band's backdrop was known only on displays that show no window; every display with a window fell to the
  worst-case alpha (0.82 dark, 0.79 light) instead of 0.65.
- Fix: 9859d0e9 (PR #13, merge bf68eaad); regression test: tests/unit/tst_glasstint.qml,
  tests/unit/tst_barbandwiring.qml
- Verification: tests: tests/unit/tst_glasstint.qml, tests/unit/tst_barbandwiring.qml; reporter's check pending
- First shipped version: 1.0.0-rc7

### URR-034: Settings > Wallpaper did not show which display a choice changes
- Status: fixed in source
- Severity (1.0 threshold): medium
- Reported: 2026-11-07, owner, Grassfield 1.0.0-rc6 (diagnostic report: no)
- Reproduction: several displays; choose a wallpaper; the preview does not change and nothing names the displays it
  changes; the owner right-clicked each desktop to check.
- Cause:
  - Under All Displays the preview showed the last display's status, possibly a display with its own wallpaper.
  - The preview waited seconds for the shell's picture, and the line under the picker named no display.
- Fix: 32120c29 (PR #13, merge bf68eaad); regression test: tests/unit/tst_settingswallpaper.qml
- Verification: tests: tests/unit/tst_settingswallpaper.qml; reporter's check pending
- First shipped version: 1.0.0-rc7

### URR-035: Quit apps stayed in the Dock, and no setting seemed to control it
- Status: fixed in source
- Severity (1.0 threshold): low
- Reported: 2026-11-07, owner, Grassfield 1.0.0-rc6 (diagnostic report: no)
- Reproduction: quit an app that is not kept in the Dock; it stays in the Dock's recent section.
- Cause: the control exists (Desktop & Dock > "Show recent apps in Dock"), but its title did not say what it controls.
- Fix: 66043990 (PR #13, merge bf68eaad): one line under the switch says it; regression test:
  tests/unit/tst_settingsdesktop.qml
- Verification: tests: tests/unit/tst_settingsdesktop.qml; reporter's check pending
- First shipped version: 1.0.0-rc7

### URR-036: Screenshots were saved to the Desktop
- Status: fixed in source
- Severity (1.0 threshold): low
- Reported: 2026-11-07, owner, Grassfield 1.0.0-rc6 (diagnostic report: no)
- Reproduction: take a screenshot with Super+Shift+3 or 4; the file lands on the Desktop; always.
- Cause: the capture helper and the toolbar defaulted to the Desktop, and the keys always used the helper's default.
- Fix: 6a1bbafb, f9bb160f, 0b32798e (PR #13, merge bf68eaad): screenshots go to Pictures > Screenshots (named in the
  session's language) and recordings to Videos; explicit choices are kept; regression test:
  tests/unit/tst_capturemodel.qml, tests/shell/capture.sh
- Verification: tests: tests/unit/tst_capturemodel.qml, tests/shell/capture.sh; reporter's check pending
- First shipped version: 1.0.0-rc7

### URR-037: Super+Shift+3, 4 and 5 did nothing on the numeric keypad
- Status: fixed in source
- Severity (1.0 threshold): medium
- Reported: 2026-11-07, owner, Grassfield 1.0.0-rc6 (diagnostic report: no)
- Reproduction: press Super+Shift with the keypad's 3, 4 or 5; nothing happens; always.
- Cause: the shortcuts were bound to the top row's keycodes only.
- Fix: 4795fadf (PR #13, merge bf68eaad): the keypad's keycodes bound to the same actions; regression test:
  tests/shell/session_services.sh
- Verification: tests: tests/shell/session_services.sh; reporter's check pending
- First shipped version: 1.0.0-rc7

### URR-038: No menu bar item for the capture toolbar (request)
- Status: fixed in source
- Severity (1.0 threshold): low
- Reported: 2026-11-07, owner, Grassfield 1.0.0-rc6 (diagnostic report: no)
- Reproduction: the capture toolbar opens only with Super+Shift+5; the menu bar cannot keep it.
- Cause: none; a request (macOS lets the Screen Capture control join the menu bar).
- Fix: 6bc2aa4c, 10aeb49d, e134ded6, 4e222ec3 (PR #13, merge bf68eaad): Settings > Menu Bar > Screen Capture, off by
  default; regression test: tests/unit/tst_settingsmenubar.qml, tests/unit/tst_statuslogic.qml
- Verification: tests: tests/unit/tst_settingsmenubar.qml, tests/unit/tst_statuslogic.qml; reporter's check pending
- First shipped version: 1.0.0-rc7

### URR-039: No way to pin a folder in Files' sidebar
- Status: fixed in source
- Severity (1.0 threshold): medium
- Reported: 2026-11-07, owner, Grassfield 1.0.0-rc6 (diagnostic report: no)
- Reproduction: right-click a folder, or drag it to the sidebar's Favorites; nothing adds it.
- Cause: Favorites were a fixed list, and only tags and saved searches had a sidebar menu.
- Fix: d17282a8, a0301046, bbadd3fb (PR #14, merge d007c54c): Add to Sidebar (menu, Ctrl+Super+T), drag in and out,
  Remove from Sidebar; regression test: tests/unit/tst_filessidebar.qml, tests/unit/files/tst_navlogic.cpp,
  tests/unit/files/tst_folderchooser.cpp
- Verification: tests: tests/unit/tst_filessidebar.qml, tests/unit/files/tst_navlogic.cpp,
  tests/unit/files/tst_folderchooser.cpp; reporter's check pending
- First shipped version: 1.0.0-rc7

### URR-040: Files' Columns view selection sometimes went back to the previous folder
- Status: fixed in source
- Severity (1.0 threshold): medium
- Reported: 2026-11-07, owner, Grassfield 1.0.0-rc6 (diagnostic report: no)
- Reproduction: Columns view; select folders, go Back or use the sidebar, then press an arrow key; the selection jumps
  to a previous folder; sometimes.
- Cause (three, each reproduced by a test):
  - a navigation flag stayed set after a click that left the location unchanged;
  - a column still listing kept its wish for the old folder, which then joined the selection;
  - a right-clicked folder was selected without the next column following it.
- Fix: cc8b5218 (PR #14, merge d007c54c); regression test: tests/unit/tst_filescolumns.qml,
  tests/unit/files/tst_folderchooser.cpp
- Verification: tests: tests/unit/tst_filescolumns.qml, tests/unit/files/tst_folderchooser.cpp; reporter's check pending
- First shipped version: 1.0.0-rc7

### URR-041: Context menus grew too wide for a long file name
- Status: fixed in source
- Severity (1.0 threshold): low
- Reported: 2026-11-07, owner, Grassfield 1.0.0-rc6 (diagnostic report: no)
- Reproduction: right-click a file with a long name; the menu grows wide.
- Cause: an item menu measured its whole label with the name; the UI audit's cap (400 pt) only kept it on the screen.
- Fix: 45ef9c25 (PR #14, merge d007c54c): names shortened in their middle to 160 pt (menu.nameMaxWidth); regression
  test: tests/unit/tst_popupmenu.qml
- Verification: tests: tests/unit/tst_popupmenu.qml; reporter's check pending
- First shipped version: 1.0.0-rc7

### URR-042: Files had no Cut (request)
- Status: fixed in source
- Severity (1.0 threshold): low
- Reported: 2026-11-07, owner, Grassfield 1.0.0-rc6 (diagnostic report: no)
- Reproduction: select items in Files and press Ctrl+X; nothing happens; Edit has no Cut.
- Cause: none; Files followed the Finder, which has no Cut (decision F-6); the owner's request wins over it (F-18).
- Fix:
  - dccf16c1, 771cbddc (PR #14, merge d007c54c): Cut and Ctrl+X, Esc cancels a cut, Move Item Here as Paste's Option
    item.
  - 14e83602, ab54725c, 19c15505 (PR #12, merge 062bd25a): the desktop's Paste Item moves cut files and never replaces
    one.
  - regression test: tests/unit/files/tst_folderchooser.cpp, tests/unit/tst_filesbrowser.qml,
    tests/shell/desktop_clipboard_probe.sh
- Verification: tests: tests/unit/files/tst_folderchooser.cpp, tests/unit/tst_filesbrowser.qml,
  tests/shell/desktop_clipboard_probe.sh; reporter's check pending
- First shipped version: 1.0.0-rc7

### URR-043: No default app choice per file type, and Grassfield's apps came second
- Status: fixed in source
- Severity (1.0 threshold): medium
- Reported: 2026-11-07, owner, Grassfield 1.0.0-rc6 (diagnostic report: no)
- Reproduction: open a picture or a PDF document from Files; another app opens it; Get Info > Change All… does not make
  Grassfield's app the default.
- Cause:
  - Change All… wrote the shared mimeapps.list, where Omarchy's defaults stay first for both sessions.
  - Open With neither marked nor set the default, and nothing made Grassfield's apps the session's defaults.
- Fix: c5dac3f3, 771cbddc, bbadd3fb (PR #14, merge d007c54c): grassfield-mimeapps.list for the Grassfield session,
  seeded only where it has no entry; Open With lists the default first; regression test:
  tests/unit/files/tst_applications.cpp, tests/unit/files/tst_folderchooser.cpp
- Verification: tests: tests/unit/files/tst_applications.cpp, tests/unit/files/tst_folderchooser.cpp; reporter's check
  pending
- First shipped version: 1.0.0-rc7

### URR-044: The screen-share picker showed several times per share
- Status: accepted limitation (owner, 2026-11-08)
- Severity (1.0 threshold): medium
- Reported: 2026-11-07, owner, Grassfield 1.0.0-rc6 (diagnostic report: no)
- Reproduction: Chromium or Google Chrome, Google Meet > Present > Entire screen; the picker shows again before the
  share starts; every share.
- Cause:
  - Chromium's WebRTC capturer captures twice for one share, the second time with the first one's restore token.
  - xdph 1.4.1 issues that token only when the picker's answer has "Remember this choice" ticked.
  - Grassfield's picker opens with that box unticked (owner decision Q14).
- Fix: none shipped; 92b3cf0b built the fix behind `SharePickerPanel.followAllowToken`, which a53a267e keeps false; the
  owner declined that amendment on 2026-11-08 (workaround: tick Remember this choice)
- Verification: tests/integration/screencast_restore.sh measures two picker runs without the box and one with it
- First shipped version:

### URR-045: Google Meet's screen-sharing preview was white
- Status: open
- Severity (1.0 threshold): high
- Reported: 2026-11-07, owner, Grassfield 1.0.0-rc6 (diagnostic report: no)
- Reproduction: Chromium or Google Chrome, Google Meet > Present > Entire screen; Meet's preview shows white.
- Cause: not reproduced in nested, where a capture streams pictures only while its display draws.
  - Hypothesis, not verified: the second picker of URR-044 blocks xdph's main loop while it runs and delays the stream.
- Fix: none
- Verification: the owner's check with a real browser is pending (docs/specs/system-dialogs.md, "After rc6")
- First shipped version:

### URR-046: Some Open and Save windows showed the GTK file chooser instead of Grassfield's panel
- Status: open
- Severity (1.0 threshold): medium
- Reported: 2026-11-07, owner, Grassfield 1.0.0-rc6 (diagnostic report: no)
- Reproduction: open or save a file from a Qt app; GTK 3's file chooser shows instead of the Files panel.
- Cause (audit b6446747):
  - Qt apps under the session's gtk3 platform theme open GTK 3's chooser in their own process (owner decision Q3).
  - LibreOffice's GTK plugin does the same.
  - Chromium and Electron apps whose first portal call came while the portal frontend was starting never retry
    (URR-047).
- Fix: none yet; a Grassfield Qt platform-theme module behind an ADR that amends Q3, before 1.0 (owner, 2026-11-08)
- Verification: GTK 3 and GTK 4 apps, Chromium, Electron, Firefox and Flatpaks reach the panel (audit b6446747)
- First shipped version:

### URR-047: The portal frontend took about 26 s to start at login
- Status: open
- Severity (1.0 threshold): medium
- Reported: 2026-11-07, owner, Grassfield 1.0.0-rc6 (diagnostic report: no), as one cause of URR-046; the integrator
  first measured the slow start on 2026-10-28 with 1.0.0rc1-4
- Reproduction: log in; xdg-desktop-portal is ready about 26 s later; an app that asks a portal meanwhile waits or falls
  back to its own dialog; every login.
- Cause (found 2026-11-08): the menu bridge's `org.freedesktop.ScreenSaver` object drops D-Bus calls without a reply; a
  call left without a reply waits for D-Bus's 25 s default timeout.
- Fix: in progress (ADR-0041 I-4)
- Verification: none yet
- First shipped version:

## Summary

| ID | Title | Severity | Status |
|----|-------|----------|--------|
| URR-001 | The secret sheets never appeared: grassfield-prompter failed at every start | high | fixed in source |
| URR-002 | Settings' sidebar kept its scroll bar visible while nothing moved | low | fixed in source |
| URR-003 | Preview's window title started under the traffic lights | low | fixed in source |
| URR-004 | Tinted Dock icons showed a coloured tile inside a pale plate at 125 % scale | low | fixed in source |
| URR-005 | Every photograph in Settings > Wallpaper said "This path can't be used" | medium | fixed in source |
| URR-006 | A right-click on the desktop of a second display opened no menu | medium | fixed in source |
| URR-007 | Desktop icons were hidden under the wallpaper on a display plugged in later | medium | fixed in source |
| URR-008 | A video opened in Preview did not start playing | low | fixed in source |
| URR-009 | A request for "magnetism" (snapping) of windows and desktop icons | low | not reproduced |
| URR-010 | Files did not list the computer's other disks and partitions | high | fixed in source |
| URR-011 | The mouse's Back and Forward buttons did nothing in Files | medium | fixed in source |
| URR-012 | Items could not be dragged out of Files' Columns view | medium | fixed in source |
| URR-013 | The Copy window showed no progress for a paste | medium | fixed in source |
| URR-014 | No way to choose the main display | medium | fixed in source |
| URR-015 | No way to set a wallpaper per display | low | fixed in source |
| URR-016 | No Input menu, and Ctrl+Space did not switch every keyboard's layout | medium | fixed in source |
| URR-017 | A click on the frontmost app's Dock tile did nothing (request: minimize the app) | low | fixed in source |
| URR-018 | GTK header bars showed no traffic lights, and Firefox showed two title bars | medium | fixed in source |
| URR-019 | No Energy settings on a computer without a battery | medium | fixed in source |
| URR-020 | No way to uninstall an app | high | fixed in source |
| URR-021 | External displays sometimes stayed black after sleep until replugged | high | fixed in source |
| URR-022 | Waking from sleep was very slow | medium | fixed in source |
| URR-023 | No way to set the main display (reported again on 1.0.0-rc6) | medium | duplicate of URR-014 |
| URR-024 | The scale set in Settings was not applied (stayed at 120 % while set to 100 %) | medium | fixed in source |
| URR-025 | A zoomed window moved to a smaller display overflowed it | medium | fixed in source |
| URR-026 | Dragging a window to the top of the screen to fill it was slow | medium | fixed in source |
| URR-027 | A window could still end up with its title bar under the menu bar | high | fixed in source |
| URR-028 | Chromium, Google Chrome and Firefox showed no traffic lights by default | medium | fixed in source |
| URR-029 | Chrome with "Use system title bar" lacks window buttons | medium | accepted limitation (owner, 2026-11-08) |
| URR-030 | Tiling did not react to dragging a tab of Chrome's title bar | medium | open |
| URR-031 | Telegram and the ArtCraft suite showed two title bars | medium | fixed in source |
| URR-032 | A Qt frameless window that draws nothing has no title bar | medium | open |
| URR-033 | The translucent menu bar was nearly opaque on some displays | low | fixed in source |
| URR-034 | Settings > Wallpaper did not show which display a choice changes | medium | fixed in source |
| URR-035 | Quit apps stayed in the Dock, and no setting seemed to control it | low | fixed in source |
| URR-036 | Screenshots were saved to the Desktop | low | fixed in source |
| URR-037 | Super+Shift+3, 4 and 5 did nothing on the numeric keypad | medium | fixed in source |
| URR-038 | No menu bar item for the capture toolbar (request) | low | fixed in source |
| URR-039 | No way to pin a folder in Files' sidebar | medium | fixed in source |
| URR-040 | Files' Columns view selection sometimes went back to the previous folder | medium | fixed in source |
| URR-041 | Context menus grew too wide for a long file name | low | fixed in source |
| URR-042 | Files had no Cut (request) | low | fixed in source |
| URR-043 | No default app choice per file type, and Grassfield's apps came second | medium | fixed in source |
| URR-044 | The screen-share picker showed several times per share | medium | accepted limitation (owner, 2026-11-08) |
| URR-045 | Google Meet's screen-sharing preview was white | high | open |
| URR-046 | Some Open and Save windows showed the GTK file chooser instead of Grassfield's panel | medium | open |
| URR-047 | The portal frontend took about 26 s to start at login | medium | open |
