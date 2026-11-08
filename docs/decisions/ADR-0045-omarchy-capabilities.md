# ADR-0045: Omarchy's capabilities in the Grassfield session
Status: Accepted as built (owner ratification of 2026-11-08: every Proposed ADR accepted at once for 1.0). Before:
Proposed (applied provisionally, owner decision of 2026-11-04: « Applique tout le plan et fait le nécessaire pour tout
finaliser ») · Date: 2026-11-04 · Decider: owner (plan), integrator (design, merge after review) · Number: 0045 (0044 is the main
display)

## Context

Grassfield is a separate session on top of an unchanged Omarchy 4 (D1, ADR-0001). It already reuses Omarchy's base: the
Hyprland environment and keyboard defaults (`config/hypr/grassfield/omarchy.lua`), the PAM services of the lock (fingerprint
included when Omarchy set it up), the update chain (`omarchy-update`, snapshot, keyring, migrations, hooks), the Store on
`omarchy-pkg-*` and `omarchy-webapp-*`, power profiles, the 1Password/Bitwarden screen-share rules, SDDM, uwsm and Limine.

What it sets aside on purpose is Omarchy's *surface*: omarchy-shell, the Omarchy menu, the tiling key bindings (D2, macOS
model). Between the two sits a set of Omarchy commands, packages and data that have a macOS counterpart and that Grassfield
did not use. On 2026-11-04 the owner asked whether it is a pity to leave them aside; the integrator compared Omarchy v4.0.6
(`basecamp/omarchy@237f1b4`, the tag of the installed 4.0.6) command by command with Grassfield and proposed a plan in three
priorities; the owner then asked to apply all of it.

Verified on the v4.0.6 tree: every command named below exists; `ddcutil`, `gpu-screen-recorder`, `hyprpicker`, `localsend`,
`qrencode`, `tesseract`, `tesseract-data-eng`, `wtype` and `zbar` are in `install/omarchy-base.packages` (installed with
Omarchy, so no new dependency for the session); `voxtype` (dictation), `fprintd` and `pam-u2f` are optional, installed by
Omarchy's own setup commands. Nothing of this was checked on the owner's machine from the cloud session (UNVERIFIED there).

`docs/compat.md` listed "screen recording bindings" and the "emoji picker" among the Omarchy features "without a macOS
counterpart": wrong (macOS has Shift-Command-5 recording and Emoji & Symbols); it also listed clipboard history, which
Grassfield has since ADR-0034. Corrected with this ADR.

## Decision

### OC-0 Rules common to every capability
1. **Reuse, do not fork.** Grassfield runs Omarchy's own command, package or data file as it is. A Grassfield copy of Omarchy
   code is made only when the command cannot serve as is (it draws Omarchy's UI, talks to omarchy-shell), MIT attribution
   kept, and the upstream file pinned in `docs/upstream/omarchy.lock` (`just check-upstream`).
2. **Every Omarchy path, command or unit used** gets a row in `docs/compat.md` and an entry in `scripts/dev/omarchy-compat.sh`
   (`just check-omarchy`), with what happens when it is missing.
3. **Graceful degradation.** A missing command or package hides the control or shows one line that says what is missing; it
   never raises an error dialog or a broken surface. Detection with `command -v` / `QStandardPaths::findExecutable` at use
   time, not at build time.
4. **Root goes through Omarchy's terminal, as Omarchy's own menu does.** A setup that needs root (fingerprint, security key,
   SSH, disk password, hibernation, dictation install) is started as
   `omarchy-launch-floating-terminal-with-presentation <omarchy-command>`, the exact argv of `default/omarchy/omarchy-menu.jsonc`
   (the same path Software Update's "Update Now" already uses, ADR-0033). Grassfield runs no code as root, writes no PAM or
   system file, adds no polkit policy. Each argv is an exact entry of the Settings launch allowlist (`systemguard.cpp`
   `isLaunch`); no argument comes from the UI. A dev session launches nothing (ADR-0019 dev guard). The page reads the state
   again when the terminal's window closes or Settings becomes active again.
5. **Names.** No Apple name (`tests/ci/ui_names.py`). Names used: "Screen Recording" « Enregistrement de l'écran », "Select
   Text in Images" « Sélectionner le texte des images », "Emoji & Symbols" « Emojis et symboles », "Dictation" « Dictée »,
   "Fingerprint & Security Key" « Empreinte et clé de sécurité », "Sharing" « Partage », "Remote Login" « Session à distance »,
   "Disk Encryption" « Chiffrement du disque », "Hibernation" « Hibernation », "Share Network" « Partager le réseau »,
   "Terminal and Developer Apps" « Terminal et apps de développement », "Send with LocalSend" « Envoyer avec LocalSend »,
   "Weather" « Météo ».
7. **macOS 27 design for every tool (owner, 2026-11-04: « Et tous ces outils doivent avoir un design mac os 27 »).** Every
   surface this ADR adds is a Grassfield surface drawn with Grassfield.Ui components and tokens to macOS 27 (layout,
   proportions, radii, states, motion; ADR-0024 glass; ADR-0039 rules), never an Omarchy UI, a gum prompt or a bare terminal
   when the system offers a way around it. So the setups of OC-0.4 are native wherever a system service has its own polkit
   action (the ADR-0030 path: the service asks polkit, Grassfield's polkit sheet asks the password, as macOS does):
   - Remote Login switch: systemd's `EnableUnitFiles`/`DisableUnitFiles` and `StartUnit`/`StopUnit` on `sshd.service` only,
     when OpenSSH is installed;
   - Disk Encryption "Change Password…": a macOS 27 sheet (current password, new password, verify) calling UDisks2's
     `org.freedesktop.UDisks2.Encrypted.ChangePassphrase` on the root file system's LUKS device, when UDisks2 answers;
   - Fingerprint: enrolling and deleting fingers in a macOS 27 sheet through fprintd's D-Bus API (`net.reactivated.Fprint`:
     Claim, EnrollStart, the EnrollStatus signal, EnrollStop, Release, ListEnrolledFingers, DeleteEnrolledFingers2), when
     fprintd is installed.
   What no system service exposes (installing a package, editing PAM files, the FIDO2 key setup, the hibernation swap file,
   initramfs and boot entry, the first OpenSSH, fprintd or voxtype install) stays Omarchy's script in Omarchy's terminal, opened
   from a macOS 27 sheet that says what will happen and why a terminal opens. That gap is documented under "Known
   limitations" (master-prompt §1 honesty rule), not hidden.
8. **Owner decisions superseded (2026-11-04).** The 2026-10-26 entries of `docs/specs/settings.md` — "no Sharing pane" and
   "Touch ID & Password is out of scope: fingerprint enrolment belongs to Omarchy's own setup, and changing a password is not a
   Settings action here" — are superseded for exactly what this ADR adds: a Sharing pane holding Remote Login only, a
   Fingerprint & Security Key pane and Disk Encryption's "Change Password…". The spirit stays: the enrolment, the PAM edits and
   the password change are Omarchy's own scripts in Omarchy's terminal; Settings shows the state and starts them.

### OC-1 Capture toolbar and screen recording (priority 1)
- **Shift-Super-5** opens the capture toolbar (macOS 27 layout): a shell layer surface centred at the bottom of the focused
  output: Close · Capture Entire Screen · Capture Selected Window · Capture Selected Portion · Record Entire Screen · Record
  Selected Portion · Options ▾ · the Capture / Record button. Esc closes it. Options: Save to (Desktop, the default, Documents,
  Clipboard, Preview), Timer (None, 5 Seconds, 10 Seconds), Microphone (None, the default input), Show Mouse Pointer. They
  persist in `capture.*` (schema). Shift-Super-3, Shift-Super-4 and Print keep their direct captures.
- **Recording** is `grassfield-capture record screen|selection` with gpu-screen-recorder (Omarchy base package), with the
  backend arguments of `omarchy-capture-screenrecording` (reference, pinned). File: "Screen Recording 2026-11-04 at
  14.05.12.mp4" (translated as the screenshots are) in the chosen place. Microphone only (macOS records no system audio).
- **Stop**: a stop item in the menu bar while recording (it shows the elapsed time), or **Ctrl-Super-Esc** (macOS
  Control-Command-Esc), both `grassfield-capture stop` (SIGINT to the recorder it started, by pid, never by name). The
  recorder's state is a private file in `$XDG_RUNTIME_DIR/grassfield/` that the shell watches. A notice "Screen recording
  saved" with "Open" (Preview plays it) follows.
- **Lock**: no capture starts while the session is locked; a recording stops when the session locks.
- **Known limitation, recordings and hidden windows** (opus security review of e3542510, MINOR-4): gpu-screen-recorder records
  a display or an area through its KMS backend (Omarchy's script calls `-w <display>` and `-w WxH+X+Y` the "kms backend";
  `gsr-kms-server` holds `cap_sys_admin`), which reads the framebuffer and skips Hyprland's `no_screen_share` rules (SEC-01).
  A recording therefore shows password manager windows and the authorization and secret sheets when they are on screen;
  screenshots keep them black. For the user: keep password managers closed and answer no sheet while the menu bar shows the
  recording item. The portal backend would honour the rules (follow-up, not done). Details and status (NOT VERIFIED, not run:
  it would record the live screen): docs/specs/security.md, "Screen-share protection".
- **Keyboard and security sheets** (opus re-reviews, MINOR): the toolbar never maps itself as Exclusive while a polkit or
  secret sheet, or its key sink's linger after a request ended under the user's typing, may hold the keyboard (no hand-over
  between displays, no opening with the keyboard), so the rest of a password never reaches it; it takes the keyboard again once
  they are gone (docs/specs/security.md, "Polkit details").

### OC-2 Text and QR codes in images (priority 1)
- **Preview** (and Glance, which shares its image view) recognises text in a still image with tesseract when it is installed:
  TSV word boxes, languages = the installed traineddata among the session language and English (`tesseract --list-langs`), run
  in the background on the file (never on the screen), nothing stored. Over text the pointer is an I-beam; a drag selects words
  in reading order; Ctrl/Super-C and the context menu's "Copy Text" copy them; "Select All Text" in the context menu.
- **QR codes**: `zbarimg` with QR only (Omarchy's options: other symbologies false-positive on screen content); each code gives a
  chip under the image: a http(s) link → "Open Link" (`xdg-open` of that URL only), anything else → "Copy".
- Setting `preview.textInImages` (default on), Settings > Language & Region "Select Text in Images" (macOS: Live Text).
- Screenshots reach it the macOS way: the capture notice's "Open in Preview".

### OC-3 Emoji & Symbols (priority 1)
- **Ctrl-Super-Space** (macOS Control-Command-Space) toggles a Grassfield panel at the pointer, clamped to its output: a search
  field, category tabs (Recently Used, Smileys & People, Animals & Nature, Food & Drink, Activity, Travel & Places, Objects,
  Symbols, Flags), a grid; arrows, Return and a click choose; Esc closes. The T0 Edit menu gets "Emoji & Symbols" where T0 has
  an Edit menu.
- **Data**: Omarchy's `$OMARCHY_PATH/shell/plugins/emojis/emojis.json` (1870 entries `{e, k}`, MIT), read at run time, never
  copied. Categories come from the Unicode group boundaries (the first emoji of each group); when a boundary is missing the
  panel shows one "All" group. Search matches Omarchy's English keywords and the translated category names (known limitation:
  no French keywords). Missing file: "Emoji list not available".
- **Insert**: Omarchy's `omarchy-menu-emoji-insert <emoji>` after the panel gave the keyboard back to the window that was active
  (it copies with `wl-copy --sensitive`, so clipboard history does not record it, then sends Shift+Insert). Known limitation:
  the clipboard does not keep its previous content.
- Recently used: `~/.local/state/grassfield/emoji-recents.json`, 30 at most, written privately.

### OC-4 External display brightness (priority 1)
- Outputs without a backlight are driven over DDC/CI with Omarchy's `omarchy-brightness-display-ddc <monitor> [N%|+N%|N%-]`
  (it caches the i2c bus per output). The brightness keys act on the output under the pointer: the backlight for the internal
  panel, DDC for an external display; the OSD shows that output's level. Settings > Displays shows a Brightness slider for an
  external display that answers DDC.
- At most one DDC process per output in flight; a slider drag sends the last value only (DDC writes take 50–200 ms).
- No i2c access (module or group missing): no slider, no key effect for that output, one journal line; documented.

### OC-5 Dictation (priority 1)
- Settings > Keyboard > Dictation (macOS 27): the switch `keyboard.dictation`, the shortcut shown (**Ctrl-Super-X**, Omarchy's
  toggle), "Set Up…" when voxtype is missing (`omarchy-voxtype-install`), "Language Model…" (`omarchy-voxtype-model`),
  "Remove…" (`omarchy-voxtype-remove`), each in Omarchy's terminal (OC-0.4). Recognition is local (Whisper), as on-device
  dictation on macOS.
- The key runs `voxtype record toggle` only when the setting is on and `voxtype` exists; Omarchy's push-to-talk on plain F9 is
  not bound (plain function keys stay the apps').

### OC-6 Fingerprint & Security Key (priority 2)
- A Settings pane "Fingerprint & Security Key" after Lock Screen. Fingerprint: shown when `omarchy-hw-fingerprint` finds a
  reader; state from fprintd's presence and the PAM files Omarchy's script edits (read only); "Set Up…" /
  "Remove…" = `omarchy-setup-security-fingerprint` / `omarchy-remove-security-fingerprint`. Security key (FIDO2): state from
  pam-u2f's presence and the user's key file; "Set Up…" / "Remove…" = `omarchy-setup-security-fido2` /
  `omarchy-remove-security-fido2`. The pane says where each one is used (lock screen, administrator prompts, sudo), as the
  scripts configure them.
- Omarchy's fingerprint setup adds `pam_fprintd` to `/etc/pam.d/polkit-1` and `sudo`: Grassfield's polkit sheet then receives
  fprintd's conversation. The sheet's device rules below assume the module announces itself before it waits: pam_fprintd
  always does, pam_u2f only with `cue`, which Omarchy's security key setup sets; a silent device module (pam_u2f without
  `cue`) would defeat them (opus re-review 2). How the sheet presents it is a security-module question (R12): checked by the security review; any
  change in `shell/security/` needs the opus reviewer's PASS.
- **No device answers a request nobody can answer** (opus security review of e3542510, MAJOR-2). Quickshell starts PAM as soon
  as polkit asks, whether or not the sheet shows the request, and offers no way to defer it; so a request whose sheet is not
  on screen in front (locked away, under the screen saver, waiting behind a secret sheet) is refused (polkit "cancelled") the
  moment PAM talks without asking, before a touch meant for the lock screen can approve it; so is one shown while the displays
  are off for inactivity. A sheet on screen in front may be answered by a touch, and a held one when it is held as "right
  after another one" (integrator decision after the re-review: macOS accepts a touch on the authorization it shows; Remote
  Login and Add Printer ask several times in a row); one held just after an unlock waits for a click (a finger left on the
  reader would answer it). A request Quickshell replaced while it was open keeps its
  PAM running with no sheet: once it talks, the current request and it are both refused (re-review MAJOR-1). A password
  prompt still waits for the user (macOS: shown after the unlock). Residual: a few milliseconds between the reader starting
  and the agent hearing it. Details: docs/specs/security.md, "Polkit details".
- **Known limitation, `pam_faillock`** (opus security review of e3542510, MINOR-5; read in Omarchy 4.0.6's scripts): where
  `/etc/pam.d/polkit-1` does not exist (this machine: polkit uses the vendor `/usr/lib/pam.d/polkit-1`, `include system-auth`),
  the fingerprint and security key setups write one with `pam_unix` only, without `system-auth`, so the authorization sheet
  loses `pam_faillock`'s lockout (sudo and the lock screen keep it), `pam_systemd_home` and `pam_env`; the removal scripts
  leave that file. Grassfield edits no PAM file (OC-0.4): the setup sheets say so before the terminal opens; the owner's fix is
  in docs/specs/security.md.

### OC-7 Remote Login (priority 2)
- Settings > General > Sharing, a pane with one row: "Remote Login" (switch). On = `omarchy-setup-security-sshd`, off =
  `omarchy-remove-security-sshd`, both in Omarchy's terminal; state = sshd.service's unit file state (the read-only systemd
  query already allowed in dev). When on: "To log in to this computer remotely, type ssh <user>@<host>".

### OC-8 Disk Encryption (priority 2)
- Settings > Privacy & Security, a "Disk Encryption" group (macOS: FileVault): on/off read from `lsblk` (a crypto_LUKS device
  under the root file system), "Change Password…" = `omarchy-drive-password` in Omarchy's terminal. Encryption cannot be turned
  on in place: the text says so, with no button.

### OC-9 Hibernation (priority 2)
- Settings > Battery (or the energy pane of a desktop), "Hibernation": available when `/sys/power/image_size` exists and
  Omarchy's `omarchy-hibernation-available` agrees; "Set Up…" / "Remove…" = `omarchy-hibernation-setup` /
  `omarchy-hibernation-remove` in Omarchy's terminal. No Hibernate item in the Grassfield menu (macOS has none).

### OC-10 Share a Wi-Fi network (priority 2)
- Wi-Fi > the current network's Details: "Share Network…" shows a QR code of the network (the payload and matrix of
  `omarchy-network-qr`, drawn by Settings) and the network name, not the password in clear. Enterprise networks: the button
  is absent (Omarchy refuses them). Reading the secret uses NetworkManager's own permission model (as `nmcli --show-secrets`).

### OC-11 Terminal and developer apps follow the appearance (priority 3)
- Settings > Appearance, group "Terminal and Developer Apps": "Match Appearance" (default off), "Light Theme" and "Dark Theme"
  (Omarchy's themes, `omarchy-theme-list`). When on, each change of the effective appearance (Light, Dark, Auto at sunrise and
  sunset) runs `grassfield-terminal-theme light|dark`, which runs `omarchy-theme-set "<theme>"` in an environment that keeps
  it out of the Grassfield session: no `HYPRLAND_INSTANCE_SIGNATURE` (no reload of Grassfield's Hyprland), dconf writes to
  Omarchy's own database (not Grassfield's isolated one, ADR-0017), the omarchy-shims first in PATH. Omarchy's theme is shared:
  the Omarchy session gets the same theme and background (said in the pane).
- **Implementation note (2026-11-04).** Keys `terminal.matchAppearance|lightTheme|darkTheme` (defaults off, "Catppuccin Latte",
  "Tokyo Night"): `appearance` is a string in contract version 1, so `appearance.terminal*` cannot exist (the reason `accent.*`
  exists). `shell/services/TerminalTheme.qml` runs `grassfield-terminal-theme light|dark` in a `systemd-run --user --scope`
  of its own (Omarchy's work never counts against the shell's CPU and memory limits, and a shell restart does not cut it), one
  run at a time, never in a dev session. What `omarchy-theme-set` 4.0.6 does from a Grassfield session, and what the helper
  makes of it: its theme staging, `theme.name`, generated files and background symlink are Omarchy's state, read by nothing of
  Grassfield (shared on purpose); its calls to Omarchy's shell (`applyTheme`, `themeTransition`, the switcher's preload) reach
  the omarchy-shims stand-in, first in PATH and followed by Omarchy's bin directory so that the login shells it starts for its
  app hooks (`bash -lc`) cannot put that directory before it, and are refused; before the omarchy-shims in its PATH comes a
  private folder the helper makes afresh at each run (`$XDG_RUNTIME_DIR/grassfield/terminal-theme-bin`, 0700, refused when
  it is a link or another user's) with two stand-ins: `hyprctl`, which fails doing nothing, so `omarchy-restart-hyprctl`'s
  `hyprctl reload` (the chain's only hyprctl call; a user's own `theme-set` hook that calls hyprctl gets the same) never
  reloads Grassfield's Hyprland, and `HYPRLAND_INSTANCE_SIGNATURE` is removed as well; Omarchy 4.5 (review of the 4.5 port): its `omarchy-theme-set` starts
  `omarchy-theme-set-herdr-machines` under `setsid`, past the helper's process-group limit, which could SSH to the herdr machines
  (this computer included) and run an unsanitised `omarchy theme set` in the live Hyprland session; the helper sets
  `OMARCHY_THEME_SYNC_FROM=grassfield`, on which that script exits at once (only it reads the variable), and
  `OMARCHY_THEME_WAIT=1`, which keeps 4.5's other retints inside the run (4.0.6 ignores both); `omarchy-theme-set-gnome`'s gsettings writes (colour scheme, GTK theme, icon theme) go through
  dconf's default profile to the user database, exactly as in the Omarchy session: ADR-0017's profile shares that writable
  database and only adds read-only defaults with a locked icon theme, so "Omarchy's own database" is the user database
  reached without that lock, and the Grassfield look stays its own (icon theme locked, GTK appearance from Grassfield's portal,
  ADR-0035 D-8; an instant of Omarchy's colour scheme is ADR-0035 decision 2b-13); the terminal reloads (Alacritty's touch,
  Kitty, Ghostty, btop, opencode, Helix signals by name, foot and tmux OSC) and the theme files of Pi, Claude Code, Hermes, T3
  Code, VS Code/VSCodium/Cursor, Obsidian and the RGB keyboard are the feature itself; the Chromium colour policy
  (`omarchy-theme-set-browser-policy`) is written through Omarchy's passwordless sudoers rule (`sudo -n -l -l`, then `sudo`
  only after that listing shows the NOPASSWD grant; no `-A` in the chain, `SUDO_ASKPASS` removed, stdin `/dev/null`), and
  where that rule does not apply the script's `exec pkexec` finds the second stand-in, `pkexec`, which fails as if absent
  (127): no administrator password sheet ever appears, and Chromium's colour is left as it was (a known limitation:
  Chromium's colour follows only with Omarchy's passwordless rule, which Omarchy installs); `omarchy-notification-send` "No background was
  found for theme" (a theme without a background, none of the 22 shipped) is a Grassfield banner (audit O6); the user's own
  `theme-set` hooks run in the same sanitised environment. Nothing restarts or signals grassfield-shell (the signals name
  kitty, ghostty, btop, opencode, helix and tmux panes). The helper also: never runs when the theme is already current, waits
  for its lock, refuses root, skips silently without Omarchy's commands, refuses without the stand-ins or when its private
  folder is a link or another user's; stdin /dev/null, a process session of its own, whose whole process group gets SIGTERM
  then SIGKILL past the run limit (the lock held until it is gone, two graces at most when what is left cannot be
  signalled). A dev session (the test) runs only with the stand-in variable, an explicit absolute OMARCHY_PATH marked as a
  tree of fakes (`grassfield-fake-omarchy` at its root; neither it nor its bin inside /usr/share/omarchy) and Omarchy's two
  theme commands resolved (links followed) directly in that tree's bin, outside the packaged Omarchy and the system
  directories; outside a dev session the stand-in variable is refused;
  `tests/shell/terminal_theme.sh` runs with a PATH of its own folders only and checks that first. Settings:
  `omarchy-theme-list` in the read-only query allowlist.

### OC-12 Per-application window rules (priority 3)
- `config/hypr/grassfield/apps.lua`: Omarchy's `default/hypr/apps/*.lua` rules that still hold in a floating-first session
  (Steam, JetBrains, QEMU, Telegram, LocalSend, DaVinci Resolve, Moonlight, GeForce Now, RetroArch, Battle.net, webcam overlay,
  picture-in-picture where Grassfield has none), each citing its source file, the upstream files pinned. Tiling-only rules are
  not ported.
- **Implementation note (2026-11-04).** 13 rules from battlenet, davinci-resolve, geforce, moonlight, retroarch, steam,
  telegram, pip and webcam-overlay, loaded by `core.lua` after `privacy.lua` (both sessions, optional). Per app, what holds:
  effects that change behaviour (installer frame, Resolve's dialog focus, `idle_inhibit = "fullscreen"`, Telegram's
  `focus_on_activate = false`, PiP `pin` and `keep_aspect_ratio`, the camera overlay's corner); not ported: `float`/`center`
  (every window), application sizes (placement.lua, macOS model), `fullscreen` at map, Omarchy's look, JetBrains'
  `no_follow_mouse` (Grassfield is click-to-focus), QEMU and LocalSend (nothing left once those go), Hermes' HUD, Meet's PiP,
  and the PiP size and corner (Grassfield keeps a PiP window's own size). `tests/shell/app_rules.sh` holds each rule to the
  cited file's text. PiP's match is the one narrowing (security review LOW 1): the browsers' exact PiP window title and a
  browser class, Omarchy's unanchored title kept as `omarchy_match` for that comparison.

### OC-13 LocalSend (priority 3)
- Files: "Send with LocalSend…" in the Share menu and the context menu of the selection, when `localsend` exists: Omarchy's
  invocation (`omarchy-menu-share`: `systemd-run --user --quiet --collect localsend --headless send <files>`), the selected
  paths as separate arguments after `--`-safe checks (local files only).

### OC-14 Weather widget (priority 3)
- A "Weather" desktop/Notifications widget (small and medium): place, temperature, condition, wind, from wttr.in's JSON for
  Omarchy's saved location (`omarchy-weather-location`, shared with the Omarchy session), refreshed every 30 minutes while the
  widget is placed, never otherwise. The gallery says that the weather comes from wttr.in. "Edit Location…" in its menu writes
  through `omarchy-weather-location --set`.

### OC-15 Deferred to M6 (Grassfield OS, owner go/no-go)
- "Erase All Content and Settings…" (Omarchy's `omarchy-system-factory-reset`, which needs the `@factory` snapshot that only the
  Omarchy Quattro installer takes) and a first-run assistant (`omarchy-provision-first-run`) belong to the ISO. Not built now.

## Consequences
- New Settings rows and panes; a new shell surface (capture toolbar), panel (Emoji & Symbols), widget (Weather) and menu bar
  item (recording); new `capture.*`, `keyboard.dictation`, `preview.textInImages` and `appearance.terminal*` settings; a new
  `grassfield-terminal-theme` helper. No daemon, no root code, no new package dependency of `grassfield-desktop` beyond what
  Omarchy installs (optional: voxtype, fprintd, pam-u2f through Omarchy's own commands).
- More Omarchy coupling: each command is a compat row and, where code derives from it, a pin; `just check-omarchy` fails when
  Omarchy renames one.
- Verification limits of the cloud session that built this: no Hyprland, no Quickshell runtime, no nested session: QML is linted
  with qmllint 6.12 against Quickshell 0.3.2's types, logic is unit-tested offline, and every visual or nested check is
  reported NOT VERIFIED until it runs on the owner's machine.

## Amendment: Omarchy 4.5.0 (2026-11-05, platform work)
Omarchy 4.5.0 is supported beside 4.0.6, which stays the minimum; the capabilities above use the same commands on both. The
supported versions are the locks of `docs/upstream/` (one per version, chosen by the tree's newest migration, a line pending
until reviewed: the header of `scripts/dev/upstream-drift.sh`); what 4.5.0 changed and what Grassfield did is the table in
`docs/compat.md` "Omarchy 4.5.0 supported". Three decisions of this amendment:
- OC-4.5-1 the Grassfield session's portal routing wins over the user's `hyprland-portals.conf` that 4.5.0's migration writes: the
  session's `XDG_CURRENT_DESKTOP` is `Grassfield:Hyprland` and the frontend's drop-in links the user's `grassfield-portals.conf`
  to it (`grassfield-portal-config`), which the frontend reads before `hyprland-portals.conf`; Omarchy's file is never touched and
  the frontend's environment is not changed (a first design, another `XDG_CONFIG_HOME` for the frontend, was refused: the apps it
  launches inherited it). macOS model: one routing, the system's.
- OC-4.5-2 `owed.service`, Omarchy's video wallpaper daemon, does not run in the Grassfield session (the shell draws the
  wallpaper, video included): one program owns the desktop picture.
- OC-4.5-3 the dictation backend system of 4.5.0 (`omarchy-dictation*`) is the Settings work's (OC-5); until it lands the
  `dictation.lua` pin stays pending.
