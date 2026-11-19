# Quick Settings spec · shell-engineer · M2

UI naming (renamed 2026-10-18, owner decision): internally `controlcenter` / `ControlCenter.qml`; the user sees "Quick Settings" (fr « Réglages rapides »). The Focus tile is "Do Not Disturb" (fr « Ne pas déranger »), subtitle On/Off. A long module title wraps to a second line inside its tile (two lines at most) at its own 13-pt bold size, as macOS does; a title never shrinks (ADR-0024 lot 4a; a single word wider than the capsule would end in an ellipsis, none of today's titles does, GF-097), the state line wraps to two lines too and only a device or network name longer than that ends in an ellipsis; the Airplane Mode state reads On/Off like macOS (tests/unit/tst_cclabels.qml); the accessible name stays "title, state".

## macOS reference behavior (described in words; measured in docs/testing/f1-reference-gaps.md, gap 6)
- Opens from the Quick Settings icon (two toggles) at the right of the menu bar. There is no shared panel: every module
  is its own glass shape on a 4-column grid (cells 63 pt, gaps 13, 291 pt wide), 14 pt from the right edge of the screen and
  about 13 pt below the bar.
- Modules: Wi-Fi / Bluetooth / AirDrop 2x1 capsules (139 x 63; we show Wi-Fi, Bluetooth, Airplane Mode), Do Not Disturb 2x1,
  Now Playing 2x2 (138 x 139, radius ~30), Display and Sound slider modules (291 x 63, radius 20, bold title, 4 pt track).
- Clicking a capsule's text opens that module as a detail panel (a list of networks or devices) in place of the grid; a back
  button returns. The icon disk (36 pt, filled with the accent when on) toggles.

## M1 subset (implemented, shell-engineer; the 320 px single panel was replaced by the modules below)
Opened by the Quick Settings menu bar icon (`qs.overlay/ControlCenter.qml`): Appearance (Light/Dark), Transparency slider (`material.transparency` 0–1, live), Reduce Transparency toggle, Reduce Motion toggle, output volume slider. Everything persists to grassfield.json through `Settings` (see ui.md). Verified: screenshots at transparency 0, 0.25, 0.6 and in the light appearance; `grassfield.json` written in the dev config dir. 

## Fidelity pass 2: floating modules (shell-engineer)
`shell/overlay/ControlCenter.qml` + `shell/overlay/controlcenter/*` (pure logic in `Model.js`, tests `tests/unit/tst_ccmodel.qml`; `Module.qml` is the glass surface).
- Grid (tokens `quicksettings.*`, `panel.controlCenterWidth` 291): cell 63, gap 13, 4 columns. Left: Wi-Fi and Bluetooth (2x1 capsules, 36-pt icon disk, title wraps to two lines, status line), then Airplane Mode and Stages (only with the plugin's `stages-available`) as 1x1 circles side by side (a hidden Airplane module leaves no empty slot). Right: Do Not Disturb (2x1) and Now Playing (2x2), shown while nothing plays too as macOS 27 does ("Not Playing", transport dimmed and inactive). Below: Display (hidden without a backlight and without a main display that answers DDC/CI), Keyboard Brightness (only with a `*kbd_backlight` LED) and Sound (mute, slider, device chevron) as 4x1 slider modules (radius 20, bold title); Appearance as a 4x1 capsule.
- Capsule details (ADR-0024 lot 4a, C-17, measured in docs/audits/visual-tahoe-2026-10-25.md § Quick Settings — partly close, 5.5/10, and docs/audits/ui-finesse-2026-10-25/f1-macos27.md § Quick Settings): an active disk is white (`colors.knob`, the 1x1 circles too) with its glyph in the accent (the selection colour when the accent is too light on white), an inactive one the material fill with the glyph in the text colour; glyph 20 pt (`quicksettings.diskGlyph`), text 6 pt after the disk (`diskTextGap`), the state line 12 pt in the title's colour (`statusSize`), not secondary.
- Slider modules: knobless sliders (`Slider.knobless`, also the Sound menu and the Appearance detail) on a 4-pt track (`control.sliderTrackCompact`) whose filled part is white and ends round, centred 42 pt below the module top (`quicksettings.sliderTrackCentre`, macOS 27), the title at 16, 10 (`sliderTitleX`, `sliderTitleTop`); a small glyph before and a large one after the track (`endGlyphSmall`, `endGlyphLarge`). Keyboard focus draws the ring around the track (no knob to carry it).
- Each module is its own `Module` (Material, no shadow). `ControlCenter.surfaces` lists the visible ones; `Overlay.qml` builds one blur region per surface (`Variants` of `Region`), so every module blurs on its own (never a fake blur); the hosting window stays one transparent layer-shell surface. Position: right edge at `quicksettings.edgeMargin` (14), top at the bar plus `quicksettings.topGap` (13), set in `Overlay.qml` (the menu bar item only opens the popup).
- Detail module: opening Wi-Fi, Bluetooth, Sound (output and input lists) or Appearance (Appearance + Material) replaces the grid with ONE 4-column module: back button, title, power toggle (Wi-Fi, Bluetooth), then the list. Esc and the Left key go back first, then Esc closes; focus returns to the capsule that opened it. Each section's list is made when it is opened and let go when it closes (a Loader per section), and the whole panel is made once in the background four seconds after start and let go (`Overlay.qml` `prewarm`): the first click only makes the instance, compiled types ready (audit note: built on click with all four sections). The chevron of a capsule shows on hover, focus or while open (a 139-pt capsule has no room for it permanently).
- Keyboard (macOS model): Tab follows the grid rows (modules are declared in row order). Up/Down move focus to the module above or below and Left/Right to the control beside (spatial navigation, `Model.navTarget`), so walking the grid with Down never changes a value. A focused slider changes with Left/Right (Home/End: ends) only; its Up/Down move focus (`Slider.verticalKeys: false`; other sliders keep Up/Down as values). Space toggles a capsule; Return too, except on a capsule with a detail module (Wi-Fi, Bluetooth, Appearance), where Return opens it, and so does Right on the last capsule of a row. Left (or Esc) goes back in a detail module, then Esc closes.
- Not built (measured in the reference, no backend or out of scope): AirDrop, Screen Mirroring, Stage Manager and Screenshot 1x1 modules, edit mode (minus badges, controls gallery, size menu).
- Wi-Fi: Quickshell Networking; scan list (deduplicated, connected first, then strength), lock icon for secured, connect to known/open networks, new WPA/WPA2/WPA3-personal network: inline password field (`connectWithPsk`), 802.1X: `nm-connection-editor`. Scanning is enabled only while the list is open. SSIDs are PlainText and elided.
- Bluetooth: paired devices, connect/disconnect, battery if exposed. Devices are not discovered or paired from here (no pairing flow).
- Airplane Mode (CC3, conflict C-QS-1 resolved: the rfkill requirement is the stricter and is implemented): an rfkill soft block of Wi-Fi, Bluetooth and cellular radios (`rfkill block|unblock wlan bluetooth wwan`, `shell/services/Rfkill.qml`, pure parsing in `Rfkill.js`). No root: `/dev/rfkill` is opened through the session's uaccess ACL (logind). State is read from `rfkill --json list` and refreshed by `rfkill event` (event driven). NetworkManager and BlueZ follow the block. When rfkill is not usable (no `/dev/rfkill`, not readable and writable by the user, or no `rfkill` tool) the capsule falls back to the Wi-Fi radio (NetworkManager) and the Bluetooth adapter power (BlueZ) and says why in the note capsule ("Airplane Mode: <reason>; using the Wi-Fi and Bluetooth switches") and in the log. Airplane Mode is its own state, as on macOS: turning it on remembers which radios were on (`Airplane.js`, persisted in `$stateDir/airplane.json`) and blocks them all; turning it off restores exactly those and leaves the others as they were. Wi-Fi switched off alone is not Airplane Mode (the state is not derived from the radios), and a persisted on is erased (written, not just hidden) once every known radio is on again, checked at start and after each change (3 s grace after switching on, so a failed block leaves nothing behind). The state file is `airplane.json`, mode 0600 in a 0700 directory. The module subtitle is On or Off. The dev guard applies to both paths and changes no state.
- Battery module (§5.2 duty, macOS Battery menu; hidden without a laptop battery): a 4x2 module "Battery" with the percentage, the power source (Power Adapter or Battery), time remaining or until full, and a Low Power Mode switch (the power-saver profile of power-profiles-daemon through `PowerProfiles`; off returns to Balanced). `shell/services/Battery.qml`, logic in `BatteryLogic.js`, test `tests/unit/tst_battery.qml`. The dev guard refuses the profile change. When the power source changes, the service runs `omarchy-powerprofiles-set autodetect`, so the profile Omarchy remembers for that source applies (Settings > Battery > Low Power Mode sets the two; Omarchy's own shell did the same); never in a dev session.
- Night Shift: a switch in the Display module (macOS keeps it in Display settings), driving `packaging/bin/grassfield-nightshift on|off|status` (interface unchanged: `status` prints `on` or `off`; hyprsunset behind it). Hidden when the helper or hyprsunset is missing. The state is read each time Quick Settings opens and after each change (no event source). The dev guard refuses the change (hyprsunset is the owner's). `shell/services/NightShift.qml`.
- Slider IPC (acceptance CC5/6): `qs ipc call controlcenter volume <0..1>` and `brightness <0..1>` make the same calls as the sliders (the dev guard answers `refused: dev guard`); `volumeLevel` and `brightnessLevel` read what the sliders show. Volume scale: PipeWire stores a linear channel volume; `wpctl`, pavucontrol and the volume keys use the cubic one (`wpctl get-volume` 0.50 is linear 0.125), and Quickshell's `PwNodeAudio.volume` already speaks the cubic one (measured nested: raw 0.007994, `wpctl` 0.20, `PwNodeAudio.volume` 0.20). The shell reads and writes it as is everywhere (sliders, menu bar label, OSD, `volumeLevel`; `Audio.qml`), so the slider is perceptual and equals `wpctl`; `volumeLevel` reads the real sink even under visual fixtures (`Audio.deviceVolume`), not the fixed 0.50. Test hooks: refused (`refused`) outside a dev session (docs/specs/security.md "IPC surface", SEC-04). Test: `tests/shell/cc_sliders_ipc.sh` (nested). The write half of the acceptance is the owner's L2 check with the sliders themselves (drag, then `wpctl get-volume @DEFAULT_AUDIO_SINK@` / `brightnessctl -m get`).
- State IPC (dev only, read-only): `qs ipc call controlcenter state` answers JSON `{appearance, dark, transparency, reduceTransparency, reduceMotion, dnd, nightShift}` (`nightShift` is `hidden` without the helper or hyprsunset, else `on`/`off`), what the shell applies. Used by `tests/visual/flow-quicksettings.sh` and `flow-settings.sh`.
- Sound: output and input device lists (PipeWire), default checked.
- Dev guard (`GRASSFIELD_DEV=1`): Wi-Fi/Bluetooth/airplane toggles, connects, device switches and mute are not executed (logged as `dev guard: ... suppressed`, a "dev: not applied" capsule appears under the modules); nothing ever changes the owner's audio (volume, mute, default output or input, volume keys), brightness, keyboard backlight or the Now Playing transport: every audio write goes through `Audio.backendWrite()`, which refuses before touching the backend (no exception path; `tests/shell/audio_dev_guard.sh`). A slider whose change is refused snaps back to the real value.
- Known gaps: Bluetooth device lists are not exercised in the dev session guard keyboard backlight and Bluetooth device rows unverified on this hardware (no kbd LED, no paired devices).

## Auto appearance (CC8, owner decision 2026-10-23: follow macOS)
Appearance offers Light, Dark and Auto in Quick Settings (Appearance detail) and in Settings > Appearance; the same `appearance` key (`dark|light|auto`) in both. macOS Auto is light by day and dark at night, switching at sunset and sunrise. Grassfield has no location service, so it uses the macOS fallback: a fixed local schedule, dark from 19:00 to 07:00 (tokens `autoAppearance.darkFromHour` 19 and `darkToHour` 7, local clock). The rule is one pure function (`ui/Grassfield/Ui/AutoAppearance.js`; C++ copy `apps/autoappearance.h` for Files and Preview, kept equal to the tokens by `tests/shell/auto_appearance_tokens.sh`). The shell, Settings, Files and Preview re-evaluate it every `autoAppearance.recheckInterval` (60 s) only while the setting is "auto", so every surface switches within a minute of the boundary. The Quick Settings capsule subtitle shows Light, Dark or Auto; its glyph shows the appearance in effect. With Settings > Appearance > Terminal and Developer Apps > Match Appearance on, Omarchy's theme follows each of these switches too (`shell/services/TerminalTheme.qml`, after `autoAppearance.terminalSettleMs`; ADR-0045 OC-11, docs/specs/settings.md).

## Purpose and non-goals
Quick settings backed by real services only (§5.8): NetworkManager (Quickshell Networking), BlueZ (Quickshell
Bluetooth), PipeWire (Quickshell Pipewire), UPower, MPRIS, brightness via `brightnessctl` or logind
`SetBrightness` (no root). Non-goals: AirDrop, Screen Mirroring (no backend), privileged commands from QML.

## Functional requirements
1. CC1 Wi-Fi tile: on/off, current SSID; expand → scan list, connect to known/open networks; secured new
   network → password field (NetworkManager agent via Quickshell if available, else open `nm-connection-editor`).
2. CC2 Bluetooth tile: power on/off, expand → paired devices connect/disconnect.
3. CC3 Airplane mode: rfkill soft block (no root); NetworkManager/BlueZ switches only as the stated fallback.
4. CC4 Do Not Disturb tile ↔ notifications DND.
5. CC5 Display brightness slider, keyboard brightness if present. The Display slider drives the built-in display's backlight; on a
   computer without one, the main display (ADR-0044, `MainDisplay.screenName`) when it answers DDC/CI, through Omarchy's
   `omarchy-brightness-display-ddc <output> N%` under `timeout -k 2 12` (ADR-0045 OC-4; one command at a time, the last value of a
   drag wins); else it is
   hidden. Choice (`services/BrightnessLogic.js` `sliderTarget`): macOS Control Center's Display slider is the built-in display's,
   and on a Mac without one the main display's; it does not follow the pointer (the brightness keys do, docs/specs/osd.md O10).
   Same module, same slider (no other look, OC-0.7).
6. CC6 Sound: output volume slider + mute; expand → output device list (Pipewire sinks); input device list.
7. CC7 Now Playing: MPRIS title/artist/art, play/pause/next/prev on the active player.
8. CC8 Material: transparency slider (`material.transparency`, 0–1) and appearance (Light/Dark/Auto).
9. CC9 Keyboard: Tab/arrow navigation across tiles, Space toggles, Esc closes; every control has Accessible.name.
10. CC10 All values update live from the services (no polling except what the service APIs require).

## Acceptance criteria
| ID | Test | Level |
|---|---|---|
| CC5/6 | change slider via IPC → `wpctl get-volume @DEFAULT_AUDIO_SINK@` matches | L1 |
| CC8 | slider at 0 / 0.25 / 0.6 → 3 screenshots, A2 contrast script passes | L1 |
| CC9 | keyboard-only scenario reaches every control | L1 |
| CC1–3 | owner checks with real hardware | L2† |

## Degraded behavior
Missing service → tile hidden with a note in the spec, never a fake toggle.

## Known limitations
- Wi-Fi Enterprise (802.1X) setup delegates to nm-connection-editor.
- Display on a desktop (CC5, ADR-0045 OC-4): only the main display's brightness, and only when it answers DDC/CI (DDC/CI on in its
  menu, the `i2c-dev` module, access to `/dev/i2c-*`); with a built-in panel the slider stays the panel's, whatever display the
  pointer is on. The slider shows the level the shell last knew: a change made with the display's buttons or in Settings shows after
  the next brightness key. The `controlcenter brightness` and `brightnessLevel` IPC hooks still speak of the backlight only (dev
  session test hooks, where no display is asked over DDC/CI).
- No AirDrop / Screen Mirroring equivalents.
