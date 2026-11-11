# Grassfield real-session test (L2), owner-run

Everything below is run by the owner. Agents install nothing and never touch your session. Verified read-only on
2026-10-20 against: Omarchy 4, Hyprland 0.56.2-2, Quickshell 0.3.1, Qt 6.11.2, SDDM 0.21.0-7.

What the packages do: `grassfield-desktop` (shell, apps, cursors, session file, the SDDM login drop-in
`/etc/sddm.conf.d/grassfield.conf`, user units that only start inside Grassfield, a no-op stand-in directory for Omarchy's
shell-restart commands) and `grassfield-compositor` (the Hyprland plugin, built against the installed Hyprland). They add one
pacman scriptlet that only prints the login check, no service that starts by itself, no D-Bus service, no file under `$HOME`.
The Omarchy session is not changed: Grassfield has its own
Hyprland config (`--config /usr/share/grassfield/hypr/session.lua`) and its units only start when `GRASSFIELD_SESSION=1`.

## 0. How you get into the session (GF-015, decision D-2: the login screen leads into the desktop)

The Omarchy SDDM theme has **no session picker**: it logs in the first session whose name contains "uwsm"
(`/usr/share/sddm/themes/omarchy/Main.qml:12-19`), and the autologin file names one session. Since the audit remediation the
package ships a supported way, without touching any Omarchy file:

- `/etc/sddm.conf.d/grassfield.conf` (sorts after Omarchy's `autologin.conf` and `99-omarchy-login.conf`, so it wins; a pacman
  backup file) lists the Grassfield directory first in SDDM's session path and makes `grassfield-login.desktop` the autologin
  session. That entry is called "Grassfield (uwsm)", so Omarchy's theme picks it.
- It runs `grassfield-login`, which starts Grassfield, or the unmodified Omarchy session when you chose it:
  `grassfield-login set omarchy` (then log out and in), back with `grassfield-login set grassfield`. The choice is one line in
  `~/.config/grassfield/login-session`; no root needed.
- After install and upgrade pacman prints the result of `grassfield-login-check` (also runnable any time: `grassfield-login-check
  --strict`); it warns when another SDDM file takes over, when the theme no longer behaves as assumed, or when autologin
  names another session.
- To go back to Omarchy's own login without uninstalling: `sudo rm /etc/sddm.conf.d/grassfield.conf` (reboot or restart SDDM).

The TTY route below stays valid as the recovery path (and for the very first test, before you install the SDDM drop-in:
install, then keep the file out of the way with `sudo mv /etc/sddm.conf.d/grassfield.conf ~/` until you want the new login).

**Who gets Grassfield (decision, GF-015 review).** `/etc/sddm.conf.d/grassfield.conf` is system-wide: once the package is
installed, **every local user** of the machine logs in to Grassfield by default (SDDM has no per-user session list here).
Each user can choose Omarchy for themselves with `grassfield-login set omarchy` (one line in their own
`~/.config/grassfield/login-session`; no root). To make Omarchy the default for everyone again, edit or delete the drop-in
(see "Uninstall" for what remains of it).

## 1. Prerequisites

1. Save your work. Be on AC power. Have this file open on a phone or another machine (the screen may be unusable).
2. Check the main checkout is the code you want:
   ```bash
   cd ~/workspace/grassfieldos && git status --short && git log --oneline -1
   ```
3. All dependencies are already installed (`pacman -T` of the depends list printed nothing, exit 0): pacman will pull
   nothing new. Optional dependencies brightnessctl, localsearch, kio-extras are installed too.
4. The password prompts you will see: `sudo` for pacman (install) and the lock screen (your real password, PAM service
   `omarchy-lock-password`). **10 wrong passwords lock your account for 120 s** (`pam_faillock deny=10 unlock_time=120`,
   `/etc/pam.d/omarchy-lock-password`). The faillock counter is per user: it also blocks TTY and sudo logins. Do not
   mash the keyboard on the lock screen.

## 2. Snapshot before installing

Omarchy has one snapper config, `root` (`/etc/snapper/configs/root`; I could not run `snapper list-configs`, the guard
hook blocks it: run it yourself first if you want to confirm).

```bash
snapper list-configs
sudo snapper -c root create -c number -d "before grassfield L2"
sudo snapper -c root list | tail -3
```

(`omarchy-snapshot create` does the same for every config.) The snapshot covers the root subvolume, including
`/var/lib/pacman` and `/etc`. It does not cover `/home`: Grassfield writes there only under its own names (section 9).

## 3. Build and install

**Once, before this build (new on 2026-10-27):** `grassfield-desktop` depends on `grassfield-keyring`, the package that
will carry the keys pacman trusts for Grassfield's own updates (ADR-0033 b.2). It is built by the private
`grassfieldhq/grassfield-packages` repository and no repository serves it yet, so without it `makepkg -si` builds and then
stops at the install (`cannot resolve "grassfield-keyring", a dependency of "grassfield-desktop"`). Build it once from
that repository, at b0e8494 or later. You already have it at `~/workspace/grassfield-packages`: update it there (if you
do not have it, clone it instead with `git clone git@github.com:grassfieldhq/grassfield-packages.git
~/workspace/grassfield-packages`):

```bash
git -C ~/workspace/grassfield-packages pull
cd ~/workspace/grassfield-packages/keyring && makepkg -si
pacman -Q grassfield-keyring                                    # grassfield-keyring 20261027-1 or later
```

It holds no key until the project's signing key exists (O11): it installs three empty files under
`/usr/share/grassfield/pacman-keyring/`, runs nothing that changes pacman's keyring, and trusts nothing. You keep it
installed; once the repository is published, updates replace it like any other package.

```bash
cd ~/workspace/grassfieldos/packaging/arch && makepkg -si
```

Expected: build, `check()` runs 232 compositor tests and 49 menu-bridge tests (all pass), then two packages are
installed (about 6.2 MiB and 0.9 MiB installed). Check afterwards:

```bash
pacman -Q grassfield-desktop grassfield-compositor
pacman -Qk grassfield-desktop grassfield-compositor
Hyprland --verify-config --config /usr/share/grassfield/hypr/session.lua    # must end with "config ok"
systemctl --user cat omarchy-sleep-lock.service | tail -4                     # shows the Grassfield drop-in
```

The build leaves `packaging/arch/src`, `packaging/arch/pkg` and `*.pkg.tar.zst` (git-ignored) and writes
`compositor/build/` in the checkout.

**Icon theme (ADR-0017, amended 2026-10-23).** The session icon theme `grassfield-icons` is its own package
(`grassfield-icons`, a dependency of `grassfield-desktop`): Grassfield's own icons, then the composed MacTahoe and Pebble
layers (Apple logo removed, Pebble folders and store icon), then Breeze (`breeze-icons`), Adwaita and hicolor. Install it
in the same `pacman -U` command as `grassfield-desktop` the first time (the theme files move between the two packages).
The earlier optional
`grassfield-whitesur-icons` package no longer exists: if you installed it, remove it with
`sudo pacman -Rns grassfield-whitesur-icons`. Then **log out and log in again**: the icon variables are read at login.
Nothing is written to `~/.config` or to your dconf database. Check afterwards (read-only):

```bash
pacman -Q breeze-icons
cat /usr/share/uwsm/env-grassfield                                  # QT_QPA_SYSTEM_ICON_THEME + DCONF_PROFILE
systemctl --user show-environment | grep -E 'QT_QPA_SYSTEM_ICON_THEME|DCONF_PROFILE'   # in Grassfield only
gsettings get org.gnome.desktop.interface icon-theme                # Grassfield: 'grassfield-icons'; Omarchy: unchanged
```
Back in the Omarchy session the last command must print your usual theme and `dconf dump /org/gnome/desktop/interface/`
must be unchanged. In the Grassfield session, changing the icon theme with `gsettings set` fails on purpose (locked key).

## 4. Log out, enter Grassfield, come back

**Normal route (after section 3 with the SDDM drop-in): restart the computer once after the first install.** SDDM reads its
configuration only when its daemon starts, so a daemon that ran before the install still starts your previous session (this
happened on the first 1.0.0-rc1 install). After that one reboot the greeter (and the autologin) starts Grassfield; later
logouts and logins need nothing. `grassfield-login-check` says "restart the computer once" while SDDM is older than the drop-in. Back to Omarchy: `grassfield-login set omarchy` in a Grassfield terminal, log out, log in.
Check once, read-only, in either session:
```bash
grassfield-login-check ; grassfield-login get
cat /etc/sddm.conf.d/grassfield.conf
```
Expected: no `WARN:` line; `get` prints `grassfield`. Gate H (stock login screen reaches the desktop) is verified by you only:
log out, type your password at the greeter, and write down what you got.

**Option A (TTY), the recovery route.**
1. Log out of Omarchy with its own menu. The SDDM greeter appears (autologin runs once per SDDM start; `Relogin` is not set).
2. Press Ctrl+Alt+F3 and log in with your user and password.
3. Run exactly the line of the session file:
   ```bash
   uwsm start -e -D Hyprland:Grassfield -N Grassfield -C "Grassfield Desktop" -- start-hyprland -- --config /usr/share/grassfield/hypr/session.lua
   ```
4. Back to Omarchy: Grassfield menu (leaf) > Log Out. Then either `reboot` from the TTY (autologin brings the normal
   Omarchy session back) or Ctrl+Alt+F1 or F2 for the greeter and log in (it picks the "uwsm" Hyprland session).

## 5. First-login checklist

Open a terminal first: **SUPER+RETURN** (`xdg-terminal-exec`). Keep it for recovery. Tick each line; note what you saw.
Gate names are the owner L2 items of the maintainers' project log (L3, L5, P1, P3, P5, R2, R3, bindings/gestures).

- [ ] Session comes up: menu bar, Dock, wallpaper in under ~10 s. Hyprland runs under `start-hyprland` (its watchdog,
      as in Omarchy's own session entry), so no "started without start-hyprland" banner should show; note it if one does.
- [ ] Lock: SUPER+CTRL+Q locks. A wrong password stays locked. The real password unlocks. Idle lock after 5 min.
      Use at most 2 wrong attempts.
- [ ] Idle and sleep: wait for the idle lock; then Grassfield menu > Sleep, wake: it must be locked. Closing the lid does the same.
- [ ] Polkit: run `pkexec true` in the terminal: a Grassfield dialog asks for the password; Cancel and a wrong password fail cleanly.
- [ ] Bindings: SUPER+SPACE (Search), SUPER+TAB (switcher), CTRL+UP (Overview), CTRL+LEFT/RIGHT (Spaces), CTRL+1..9,
      CTRL+F2 (focus the menu bar), CTRL+F3 (focus the Dock): both are open real-keyboard checks in the maintainers' project log.
- [ ] Trackpad: 3-finger swipe left/right (Space), up (Overview open), down (close), two-finger natural scroll, tap, two-finger click.
- [ ] Wi-Fi, Bluetooth, volume, brightness (Control Center and Settings). **These change real system state that survives
      into Omarchy** (NetworkManager radio, Bluetooth power, default audio device via wpctl, brightness). Put them back after.
- [ ] Multi-monitor (R3): plug an external display, mirror/extend, move windows, Dock and menu bar per output, unplug.
- [ ] Notifications: `notify-send test hello` three times, after 30 s of nothing each time. Note the delay of the first
      banner (the open "banner first-show stall" item; nested measured 100-1300 ms).
- [ ] Global menus (L5): open Files, Settings, a Qt or GTK app: the menu appears in the menu bar. Note apps that do not.
- [ ] Files, Settings, Preview: open each, browse, change a harmless setting, Space on a file in Files opens Glance.
- [ ] Log Out from the Grassfield menu returns to the greeter or TTY.

**New in 0.4.0-7** (installed with `sudo pacman -U grassfield-desktop-0.4.0-7-x86_64.pkg.tar.zst
grassfield-compositor-0.4.0-7-x86_64.pkg.tar.zst` from `packaging/arch`, then log out and in):

- [ ] Click to focus: lock (SUPER+CTRL+Q) with the pointer away from every window, unlock, type at once: the keys reach
      the window that was in front, with no click. Click another window: it gets the keyboard.
- [ ] Font: menus, Settings, Files, a GTK app (Nautilus), Chromium's UI and a web page using the system font show Inter.
      The terminal keeps its own font. Override if needed: `~/.config/grassfield/fonts.conf` (fontconfig syntax).
- [ ] Icons: app icons come from Breeze or Adwaita (WhiteSur is gone). Note any app showing a generic placeholder.
- [ ] Windows: a browser's dialogs and Picture-in-Picture keep their own size; a browser's first window still opens large.
- [ ] Dock: a click bounces the icon until the first window appears; a click on a running app brings its windows
      forward; minimized windows come back.
- [ ] Apps: plain F4 is left to applications; Apps opens with the Launchpad key (if the keyboard has one), the 4-finger
      pinch and the Dock tile.
- [ ] Overview: open it with nothing chosen, press Return: it closes; the first arrow key moves the ring.
- [ ] Notification Center: Tab, Delete and Return keep the focus where you expect after new notifications arrive.

**New in 0.4.0-8** (`sudo pacman -U grassfield-desktop-0.4.0-8-x86_64.pkg.tar.zst
grassfield-compositor-0.4.0-8-x86_64.pkg.tar.zst` from `packaging/arch`, then `systemctl --user restart
grassfield-shell`; the plugin and the Hyprland config did not change since 0.4.0-7, so no re-login is needed):

- [ ] Login: no "Compositor extension not loaded" banner, titlebars and minimize work at once. If the extension answers
      late, the shell keeps asking for 5 minutes and recovers by itself (no shell restart needed any more).
- [ ] Wallpaper: Settings > Wallpaper: the Grassfield artwork, a colour, one of your pictures, a folder carousel. A
      change crossfades in about a second; the menu bar text stays legible over a light and a dark picture.
- [ ] Icons: Settings > Appearance > icon style Dark, Clear and Tinted: every app icon at 24 px and above sits on a
      plate; small list icons keep their own artwork. Note any icon that disappears or turns unreadable.
- [ ] Desktop: right click > New Folder twice quickly: "untitled folder" and "untitled folder 2", no error.
- [ ] Settings: no "Binding loop" lines in `journalctl --user -b | grep SettingsGroup` after opening a few panes and
      resizing the window.

**New in 0.4.0-9** (`sudo pacman -U grassfield-desktop-0.4.0-9-x86_64.pkg.tar.zst
grassfield-compositor-0.4.0-9-x86_64.pkg.tar.zst` from `packaging/arch`, then log out and back in: the plugin (0.10.0-chrome)
and the Hyprland config changed):

- [ ] Spotify (and any app that restores a large or top-left window): it opens with its title bar below the menu bar
      and can be moved; a window larger than the screen is made to fit.
- [ ] Menu bar: a menu opens on the press; with a menu open, moving onto another title or status icon opens that menu
      without a click; Left/Right in a menu go to the neighbouring menu; no highlight when you only hover.
- [ ] Notification Center: a click on the clock slides it in from the right edge; nothing sweeps across the screen.
- [ ] Desktop: right click on the desktop and on an icon: the full macOS-like menus (Paste, Get Info, Change Wallpaper,
      Edit Widgets, Clean Up By; Open With, Compress, Duplicate, Make Alias...); shortcuts right-aligned; frosted menu.
- [ ] Window titlebars: macOS 26 size, hover symbols on the three lights, grey lights on inactive windows.
- [ ] Dock: magnification (if on) is smooth; tooltips after a short dwell; a press-and-hold menu never moves a tile.
- [ ] Search: Tab reaches the filter chips; "No Results" no longer flashes while the search still runs.
- [ ] Settings > Wallpaper: the optional "Picture of the Day" (off by default) shows its author, source and licence links.

**New in 0.4.0-10** (`sudo pacman -U grassfield-desktop-0.4.0-10-x86_64.pkg.tar.zst
grassfield-compositor-0.4.0-10-x86_64.pkg.tar.zst` from `packaging/arch`, then log out and back in: the plugin
(0.12.0-pointer) and the Hyprland config changed):

- [ ] Window tiling: drag a window by its title bar to the left or right screen edge (half), to the top or bottom of that
      edge (quarter), onto the menu bar (fill); a translucent frame shows the place first; dragging it away gives its size
      back. Window menu > Fill, Center, Move & Resize; Super+Ctrl+arrows, Super+Ctrl+R. Settings > Desktop & Dock >
      Windows has the three switches.
- [ ] Menu bar: the icons of your apps (Spotify, Discord, Steam...) with their menus; Now Playing while music plays
      (artwork and controls); the Search magnifier; it reveals over a full-screen window at the top edge; Settings >
      Menu Bar > "Automatically hide and show the menu bar".
- [ ] Menu bar: a second click on an open menu title closes it even without moving the mouse.
- [ ] Grassfield menu > Recent Items: the apps you launched and your recent documents; Clear Menu.
- [ ] Dock: its menu lists the app's windows; Option (Alt) shows Force Quit and Hide Others; Trash > Empty Trash…;
      an app asking for attention bounces; Settings > Desktop & Dock > Size, Position (left, bottom, right); with two
      screens one Dock that follows the screen whose bottom edge you touch; Super+Alt+D turns hiding on or off.
- [ ] Dock: badges and progress set by the apps themselves (Telegram, Discord, Firefox downloads).
- [ ] Two screens: the menu bar of the screen that is not active is dimmed.

**New in 0.4.0-11** (the three packages in ONE command, from `packaging/arch`, because the icon theme moves from
`grassfield-desktop` to its own package: `sudo pacman -U grassfield-desktop-0.4.0-11-x86_64.pkg.tar.zst
grassfield-compositor-0.4.0-11-x86_64.pkg.tar.zst grassfield-icons-0.4.0-11-any.pkg.tar.zst`, then log out and back in):

- [ ] Icons: the composed `grassfield-icons` pack (MacTahoe, Pebble folders and store bag, Pebble, then Breeze): Dock,
      Apps, Search, Files, the desktop. No Apple logo anywhere (tell me the app name if you see one: it goes on the list).
- [ ] Icons: Settings > Appearance > Icon appearance Dark, Clear, Tinted work on every icon; folder colours and folder
      symbols on the new folders. Known: in those three modes a rounded-square icon still sits inside a second plate
      (fix in progress, next package).
- [ ] Windows: a zoomed window (green button or double-click on the title bar) that you click while another window is
      in front of it comes to the front (your Spotify-behind-Chrome case); clicking the other window brings it back in
      front.

**New with the audit remediation (GF-AUDIT-001: GF-015, -023, -024, -025, -032 and the dropped Omarchy services).** Install the
rebuilt packages as before, then log out and in (the Hyprland config, the uwsm environment and the units changed). Only you
can run these; the ones marked (VM) are best done on a snapshot or a spare machine. Each line says what you should see.

- [ ] Keyboard (GF-023): `hyprctl getoption input:kb_layout`, `input:kb_options`, `input:repeat_rate`, `input:repeat_delay`,
      `input:numlock_by_default` (read-only) print the same values as in the Omarchy session (layout from `/etc/vconsole.conf`;
      `compose:caps,shift:both_capslock_cancel`, 40, 250, 1). With a non-US layout (VM): type your password on the lock screen
      with that layout. `journalctl --user -b | grep "grassfield: Omarchy include"` prints nothing.
- [ ] Word navigation (GF-024): in Search, a Settings text field and a browser text field, Alt+Left/Right moves by word,
      Alt+Shift+Left/Right selects by word, Alt+Backspace deletes the previous word. In a terminal (kitty/Alacritty/foot) Alt+arrows
      are unchanged (your tmux/vim keys). Ctrl+Left/Right still switch Desktops, Ctrl+1..9 the Desktop, Ctrl+Up opens Overview.
      Verify the forwarding itself with `tests/compositor/forward_keys.sh` in the nested session (below).
- [ ] Command+number (GF-024): in Files Super+1, +2, +3, +4 switch the view (Icons, List, Columns, Gallery) and Super+Up goes to
      the enclosing folder; in Preview Super+9 is Zoom to Fit. In a browser Super+1..9 selects the tab. Super+[ and Super+]
      are Back and Forward (browser, Files). The menus of Files and Preview still print "Ctrl+1": that is the pending apps item.
- [ ] Log Out, Restart, Shut Down (GF-025, on a snapshot or a spare session): open an editor with unsaved text, choose Log Out.
      The window gets a close request and its "Save changes?" dialog stays; the session does NOT end. After 15 s a notice says
      "Can't log out now: <app> ..." with the button "Log Out Anyway". Save, then Log Out again: it ends at once. An app that quits
      cleanly ends the session after about one second. Restart and Shut Down behave the same. Expected `echo $?`: not applicable
      (started by the shell); the log is `journalctl --user -b -t grassfield-shell | grep session-end`.
- [ ] Omarchy update guard (GF-032, **VM or a disposable session only**: it must not touch your real Omarchy shell):
      in a Grassfield terminal run `omarchy-restart-shell; echo "exit $?"`. Expected: "Grassfield session: the Omarchy shell is
      not used here, nothing to restart." and `exit 0`; `pgrep -af "quickshell.*omarchy"` shows no Omarchy shell and the Grassfield
      session has one menu bar, one Dock, one notification server (`busctl --user status org.freedesktop.Notifications`). Then
      `type omarchy-restart-shell` prints a path under `/usr/lib/grassfield/omarchy-shims/`. A full Omarchy update is best run from
      the Omarchy session; if you run it in Grassfield the end must print "Grassfield session: ..." and nothing else changes.
- [ ] Login (GF-015, section 0): log out at the greeter, enter the password: Grassfield starts without a TTY. After a reboot with
      autologin: Grassfield. `grassfield-login set omarchy`, log out, log in: Omarchy; back with `grassfield-login set grassfield`.
- [ ] Screenshots: Super+Shift+3 (the screen), Super+Shift+4 (drag a selection), Super+Shift+5 (the picker); Print also. A notice
      shows, the picture is in `~/Pictures` and on the clipboard (`wl-paste -t image/png | file -`). Clicking the notice does not open an
      editor (known: it needs a hint Grassfield's server does not run).
- [ ] Crash notice (macOS model: "<App> quit unexpectedly" only when an application of yours is gone after a crash; needs a
      core dump, `coredumpctl list` shows it). No banner: from a terminal `sleep 300 & kill -SEGV %1` (the terminal's scope
      still holds the shell), a crashing helper of an app that keeps running, the shell's own crashes (systemd restarts it).
      With a banner, safe procedure (one throwaway Foot in a scope of its own, one PID, checked before it is killed):
      `uwsm-app -u app-Hyprland-foot-gfcrashtest.scope -- foot`, then in your first terminal
      `s=/sys/fs/cgroup/user.slice/user-$UID.slice/user@$UID.service/app.slice/app-graphical.slice/app-Hyprland-foot-gfcrashtest.scope`,
      `cat $s/cgroup.procs` (the new Foot and its shell), `ps -o pid,comm,args -p <the pid whose comm is foot>` (must be the
      throwaway one; a `foot --server` serves all its windows from one process, never use it for this), `kill -SEGV <that pid>`.
      Within about 10 s a banner "Foot quit unexpectedly" (French session: « Foot » a quitté de façon inattendue) with a
      "Reopen" button (« Rouvrir ») appears; Reopen starts Foot again in its own scope (`systemctl --user list-units 'app-*foot*'`).
      A second crash of the same app within 10 minutes does not repeat.
- [ ] Low battery (unplugged laptop): at 20 %, 10 % and 5 % one banner each ("Low battery" / "Very low battery"). To test without
      draining: `GRASSFIELD_POWER_SUPPLY` cannot be faked in the running unit; read the log instead after a real discharge:
      `journalctl --user -u grassfield-battery-watch`. Desktop without battery: the unit is "inactive (condition)".
- [ ] Removable media: plug a USB stick: it is mounted under `/run/media/$USER/` within seconds and Files lists it
      (`systemctl --user is-active grassfield-automount` prints `active`).
- [ ] Lid (needs an external display for the second half): lid closed without a display: the screen locks, the machine sleeps
      (wake: locked). Lid closed with an external display: the machine keeps running on that display, the laptop panel is off,
      no lock; windows moved to the external display. Open the lid: the panel is back with your usual scale and position.
      Unplug the display with the lid closed: the panel comes back (`systemctl --user status` shows no failure; `grassfield-lid reconcile`
      does the same by hand).
- [ ] Pending migrations notice: when Omarchy has pending migrations the login shows "Pending Omarchy migrations"; clicking the
      banner opens a floating terminal that runs the migrations (nothing pending: no notice).
- [ ] Night Shift: `grassfield-nightshift toggle` warms the screen (`grassfield-nightshift status` prints `on`), again turns it off.
- [ ] No second shell after the checks above: `systemctl --user list-units 'omarchy-*' 'grassfield-*' --no-pager` shows no
      `omarchy-crash-watch`, `omarchy-migrate-notify` or `omarchy-sleep-lock` active in the Grassfield session (condition result "no").
- [ ] Omarchy dependency check: `cd ~/workspace/grassfieldos && just check-omarchy` ends with "all Omarchy dependencies present".

Nested-session checks I could not run (the session refuses to start in my sandbox; bare commands, ask before running):

```bash
just nested-up
tests/compositor/forward_keys.sh        # Alt+arrows, Super+digits and Super+Up reach a client as the Ctrl chords; terminals keep Alt
scripts/nestctl reload                  # T-OM4: a reload keeps bindings, one plugin, one shell (then: scripts/nestctl binds | grep -c ALT)
just nested-down
```
Expected for `forward_keys.sh`: every line `PASS`, final exit status 0. If it prints FAIL for a `code:` key, Hyprland's `send_key_state`
does not accept keycodes on 0.56.2: report which; the Super+digit forwarding then needs keysyms (works on US layouts only).

## 6. Known issues on main right now

Build 1.0.0-rc1 (2026-10-25, from main 2b224ea; the 0.4.0 notes below still apply unless replaced here):
- New since 0.4.0-11: GTK apps (Nautilus, Evince, ...) and Chromium show their own close, minimize and zoom buttons on the
  left (the Grassfield session's GNOME button layout default is `close,minimize,maximize:`) and Grassfield draws no second
  titlebar for Chromium's browser, Obsidian, Evince and Nautilus; web apps (`chrome-*`) keep Grassfield's traffic lights.
  If you set a button layout yourself, yours wins and those apps may show fewer buttons:
  `gsettings get org.gnome.desktop.wm.preferences button-layout` should print `'close,minimize,maximize:'`.
- New: the menu bar, widget and lock-screen clocks no longer spin during the daylight-saving change (seen on 2026-10-25).
- New: media art comes only from public https hosts, and every image from your own icon folders, notifications and the
  tray is re-encoded by a helper before the shell shows it: tell me if an icon or an album cover you expect is missing.
- Dock folder stacks (Downloads): this build still has the first implementation. On a folder with tens of thousands of files
  it can use noticeable CPU and update slowly; the native helper that fixes it is under review and not in this build.
- Mission Control (Overview) closing with no window open can stutter with transparency on (measured in the nested session
  only; your hardware is the real measurement: tell me what you see).
- The lock screen after a keyboard is unplugged and plugged back (Bluetooth or USB) is NOT VERIFIED: try it once (lock, unplug
  the keyboard, plug it back, type your password).

Earlier notes:
- Search/Apps keyboard focus on two outputs: under a fix pass.
- Attention bounce: most apps that ask for attention get the focus at once (Hyprland focuses activation requests;
  telling a user-triggered activation from another one is not possible in Hyprland 0.56.2), so the bounce shows mainly
  for apps that only set an urgency hint.
- Tray icons and Now Playing were checked with test items and a test player, not yet with your real apps: tell me if one
  is missing or its menu misbehaves.
- Fonts: a GTK/Qt app that asks by name for a font that is not installed (Roboto, Ubuntu, Verdana, ...) gets Liberation
  Sans, not Inter (documented limit; browsers are not affected).
- Stages are off by default.
- Not in 0.4.0-8 yet (under review or in progress): Dock hold-to-menu, the minimize funnel effect, the new traffic-light
  and titlebar size, online daily wallpapers (Wikimedia Commons), the contrast fixes, the unified toolbar for
  Grassfield apps.
- Apps search placeholder in dark at high transparency over a white wallpaper is slightly under the contrast target.
- The notification banner first-show delay is unmeasured on real hardware (you are the measurement).
- Omarchy's own shell (bar, notifications, launcher, lock) does not run inside Grassfield, by design, and nothing starts it
  there (stand-ins for the restart commands, GF-032). Omarchy's keybindings, menus, clipboard history, emoji picker and
  screen-recording keys are not available; screenshots (Super+Shift+3/4/5), removable media, lid handling, crash and low-battery
  notices, Night Shift (`grassfield-nightshift`) and the keyboard defaults are provided by Grassfield. GTK applications keep the
  cursor theme already set in dconf (Grassfield does not write it; Qt and Hyprland get "grassfield-cursors" through the environment).
- Dock "Open at Login" writes `~/.config/autostart/<app>.desktop`, which Omarchy's session also reads. Remove the file to undo.
- Omarchy's own crash-watch and migrations notice are switched off in Grassfield (drop-ins); Grassfield's own notices replace
  them (no AI diagnosis; a click on the screenshot notice does not open an editor).
- Settings > Keyboard does not list the new forwarded keys (Alt+arrows, Super+number) yet, and the menus of Files and Preview still
  print Ctrl+1..4, Ctrl+Up and Ctrl+9 for the keys that Super+number now delivers (apps and Settings items).
- Alt+Left/Right in a browser or Files no longer means Back/Forward (it is word navigation); use Super+[ and Super+].

## 7. Collecting logs for me

From a Grassfield terminal or a TTY, after the test (the files are in your home; look at them before sharing):

```bash
mkdir -p ~/grassfield-logs && cd ~/grassfield-logs
journalctl --user -b -u grassfield-shell      --no-pager > shell.log
journalctl --user -b -u grassfield-menu-bridge --no-pager > menu-bridge.log
journalctl --user -b -u 'wayland-wm@*'        --no-pager > compositor-unit.log
journalctl -b -p warning --no-pager > system-warnings.log
ls "$XDG_RUNTIME_DIR"/hypr/*/hyprland.log && cp "$XDG_RUNTIME_DIR"/hypr/*/hyprland.log .   # copy before reboot (tmpfs)
cp ~/.cache/hyprland/hyprlandCrashReport*.txt . 2>/dev/null                               # only after a crash
qs log -p /usr/share/grassfield/shell --tail 2000 > quickshell.log
coredumpctl list --no-pager > coredumps.txt
```

Also write down: time of the problem, what you pressed, which monitor.

## 8. Recovery

**Lock stuck (cannot unlock).**
1. Wait 2 minutes if you typed 10 wrong passwords (`faillock`); `sudo faillock --user "$USER" --reset` clears it.
2. Ctrl+Alt+F3, log in. `loginctl list-sessions` lists the sessions; the Grassfield one is the graphical session
   (`loginctl session-status <id>` shows Hyprland in its process tree).
3. Restart the shell, which re-reads the lock marker and shows the lock screen again:
   `systemctl --user restart grassfield-shell.service`. Return with Ctrl+Alt+F1/F2 (the VT of the session).
   With packages older than 0.4.0-2, applications started from the Dock, Search, Apps or the desktop run inside the
   shell's unit and this restart closes them (ADR-0011 amendment); from 0.4.0-2 each runs in a scope of its own.
4. `loginctl unlock-session <id>` exists and its syntax is right, but **Grassfield does not listen for logind's Unlock
   signal** (nothing under `shell/` handles it), so it does not unlock. Do not rely on it.
5. Last resort, loses open windows: `loginctl terminate-session <id>` (the Grassfield session id from step 2), or `systemctl reboot`.
   A locked Hyprland stays locked when the shell dies by design; that is not a bug.

**Broken session (black screen, no bar).** Ctrl+Alt+F3, log in, `systemctl --user status grassfield-shell.service`,
then `systemctl --user restart grassfield-shell.service`. If the compositor itself is gone you are on the greeter or the
TTY: start Omarchy (`reboot`).

**Compositor extension off after a Hyprland update.** The extension only works with the Hyprland build it was compiled
for (ADR-0009, "Amendment 2026-10-23"). When no build matches the Hyprland that runs, the session loads none: no
titlebars/traffic lights, no minimize animation, no global menus, and one notice names the Hyprland version. Recovery, in
a terminal of the Grassfield session, as yourself (never with sudo; it refuses root):
`grassfield-compositor-rebuild` (about a minute; it needs cmake, gcc, make and pkgconf: `sudo pacman -S --needed cmake gcc
make pkgconf` if it says they are missing), then log out and back in. `grassfield-compositor-rebuild --check` tells which
build matches, and why your own build is not used when it is not (every directory from `~/.cache` down to it must be
yours, not writable by group or others, and not a symlink). To have this done automatically after each Hyprland update, turn on Settings > Desktop & Dock > "Rebuild
the compositor extension after Hyprland updates" (the build then runs in the background and loads itself when it can).
A new `grassfield-compositor` package built for the new Hyprland also fixes it (`cd ~/workspace/grassfieldos/packaging/arch
&& makepkg -si`). To run without it: `sudo pacman -Rns grassfield-compositor`.

**Cannot reach Omarchy.** The login now starts Grassfield. In a Grassfield terminal: `grassfield-login set omarchy`, log out, log in.
If Grassfield does not start at all: Ctrl+Alt+F3, log in, run `grassfield-login set omarchy`, then `reboot` (or
`sudo rm /etc/sddm.conf.d/grassfield.conf` to restore Omarchy's own login completely; `grassfield-login-check` explains what it found).

## 9. Uninstall

```bash
sudo pacman -Rns grassfield-login-themes grassfield-desktop grassfield-wallpapers grassfield-compositor grassfield-icons
```

`grassfield-login-themes` (ADR-0042) is built and installed by the same `makepkg -si` and depends on `grassfield-desktop`, so
it goes in the same command; it activates nothing by itself. If you made its login or boot theme the current one, revert
them first ([login-boot-themes.md](login-boot-themes.md), section 3).

Every package the build installed: `grassfield-icons` (the icon theme, 30,000 files, 60 MiB) and `grassfield-wallpapers`
(the sixteen photographs, ADR-0040 step 2c; `grassfield-desktop` depends on it) are installed with the others, explicitly,
and are not removed when they are left out of the command (GF-046). This removes only Grassfield: every dependency is either
explicitly installed or required by other packages (checked with `pacman -Qi`). Check afterwards with
`pacman -Q grassfield-login-themes grassfield-desktop grassfield-wallpapers grassfield-compositor grassfield-icons` (each:
"was not found"). Left behind by a package removal (only Grassfield's own paths; the public `grassfield-install.sh --uninstall`
deletes the session-only files and keeps your settings and state by design, GF-010):

```bash
# Session-only files: they do nothing outside Grassfield (the installer's --uninstall deletes them)
rm -f ~/.config/xdg-desktop-portal/grassfield-portals.conf
rm -rf ~/.local/share/icons/grassfield-cursors-custom ~/.cache/grassfield
# Your Grassfield settings and state, with the session's default-app list (the installer keeps them and prints this line)
rm -rf ~/.config/grassfield ~/.config/grassfield-mimeapps.list ~/.local/state/grassfield
rm -rf "$XDG_RUNTIME_DIR/grassfield"   # tmpfs, gone at reboot anyway
ls ~/.config/autostart/               # delete only entries you added through the Grassfield Dock
```

System side: `pacman` never removes the `grassfield-update` system group that a package's sysusers.d file created (the primary
group of `grassfield-update-migrate.service`, no member). The installer's `--uninstall` keeps it too and says so, as Arch does for system groups (a reused gid would give access to files the
group left behind); it is invisible and harmless. To remove it anyway, once you have checked that
`sudo find / /home -xdev -gid $(getent group grassfield-update | cut -d: -f3)` finds nothing: `sudo groupdel grassfield-update`.
(`-xdev` stops at each filesystem boundary, and on Omarchy `/home` is a separate btrfs subvolume, so it is named too: the
migration markers under `~/.local/state/omarchy/migrations` that carry this gid live there; add any other mount you have.)
`plymouth-set-default-theme` leaves `/etc/plymouth/plymouthd.confe` (its own `sed -ie`) after each call; if you switched the boot
theme by hand, `sudo rm /etc/plymouth/plymouthd.confe` once you have checked it holds nothing you wrote.

The SDDM drop-in is a pacman backup file: if you edited it, removing the package leaves it as
`/etc/sddm.conf.d/grassfield.conf.pacsave`. SDDM reads only files named `*.conf` from that directory (name filter in its
configuration loader, from SDDM's source; **not verified on this machine**), so a `.pacsave` copy is not read and the login
goes back to Omarchy's own. Check after uninstalling, as your user: `ls /etc/sddm.conf.d/` must show no `grassfield.conf`; delete
the `.pacsave` with `sudo rm /etc/sddm.conf.d/grassfield.conf.pacsave` if you want it gone. An unedited drop-in is removed with
the package.

Not Grassfield-only: `~/.local/share/Trash` (shared trash), Wi-Fi/Bluetooth/audio state you changed.

## 10. Rollback through the snapshot

If the system is broken (not just the session):
1. Reboot, open the Limine menu and boot the "before grassfield L2" snapshot.
2. Make it permanent: `omarchy-snapshot restore` (runs `sudo limine-snapper-restore`).

Home is not rolled back (the snapshot does not include it).
