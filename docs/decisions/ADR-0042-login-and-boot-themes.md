# ADR-0042 — Login and boot themes (ADR-0040 step 10, IQ-L1 C)

Status: Accepted as built (owner ratification of 2026-11-08: every Proposed ADR accepted at once for 1.0). Before:
Proposed (2026-10-31), under the owner's IQ-L1 C (« SDDM et Plymouth », 2026-10-29, with the integrator's
conditions; repeated on 2026-10-31 for the one pull request #79). Needs the opus security review before any merge, and
the owner runs every root step.

## Context

ADR-0040 (identity) gives Grassfield one look from the wallpaper to the exit. Before the session it is Omarchy's: Limine,
the disk password drawn by Plymouth (Omarchy's boot theme), SDDM (Omarchy's theme; autologin by default, the greeter only
after a log out, or on machines without autologin), then `grassfield-login` routes to the Grassfield session
(`packaging/sddm/grassfield.conf`). The owner chose IQ-L1 C: an SDDM theme in the lock screen's layout and a Plymouth theme
with the mark.

The integrator's conditions (ADR-0040 section 3, 2026-10-29), all kept here:
- its own ADR first (this one) and an opus security review;
- SDDM's own PAM service, no PAM file of ours; no change to Omarchy's Limine or disk-encryption flow beyond the theme;
- SDDM: a theme for SDDM's own greeter, not a greeter (master-prompt §4 allows "SDDM theming later");
- Plymouth is outside master-prompt §4's allowance (plymouthd runs as root in the boot image and draws the disk-password
  prompt): the owner's explicit go-ahead is needed inside this ADR. **Recorded:** the owner's « SDDM et Plymouth »
  (2026-10-29, IQ-L1 C) and, again, on 2026-10-31 (« SDDM et Plymouth », asked with the conditions: plymouthd runs as root
  in the boot image, a broken theme must never hide the disk-password prompt, every root step is the owner's command);
- every root step (install, initramfs rebuild, enabling a theme) is a command the owner runs;
- a broken theme must never hide the disk-password prompt: a tested fallback to the text prompt;
- the last identity step, after the lock steps (4a, 4b and 5 are in #79).

## Decision

### 1. What ships, and what activates it
A new package `grassfield-login-themes` (built by `packaging/arch/PKGBUILD`, depends on `grassfield-desktop`) installs two
themes and nothing else: no PAM file, no SDDM or Plymouth configuration, no hook, no service, no initramfs change.
- `/usr/share/sddm/themes/grassfield/` (`packaging/sddm/theme/`): `Main.qml`, `Strings.js` (its few words in English and
  French: the greeter loads no Grassfield catalog), `metadata.desktop`, `theme.conf`.
- `/usr/share/plymouth/themes/grassfield/` (`packaging/plymouth/`): `grassfield.plymouth` and its PNG images, rendered at
  build from SVG by `rsvg-convert` (already a makedepend).
- Licences: the theme's QML is source code (MIT, as the repository); the images drawn in `build.sh` are CC-BY-SA-4.0; the
  mark is the owner's, all rights reserved (`branding/LICENSES.md`, installed with the package).

Installing the package changes nothing on screen. The owner activates each theme with the commands of
`docs/owner-setup/login-boot-themes.md` (root), and each has its revert command there. Removing the package leaves the
active configuration pointing at a missing theme, which both programs survive (section 4); the guide says to revert
first.

### 2. The SDDM theme (a theme, not a greeter)
- SDDM's own greeter (`sddm-greeter-qt6`) runs it as the `sddm` user; authentication is SDDM's (`sddm.login(user,
  password, session)`, SDDM's own PAM service `sddm`); the theme never touches PAM, files, the network or a process. The
  password lives in one `TextInput` (`echoMode: TextInput.Password`), is handed to `sddm.login` once per Return and the
  field is cleared at once and on `loginFailed`; it is never logged, bound to anything else or stored.
- Layout: the lock screen's (ADR-0040 section 4): the default Grassfield artwork (`GrassfieldArtwork` from
  `Grassfield.Ui`, the system-wide module of `grassfield-desktop`: the greeter has no access to the user's wallpaper), the
  banded scrim, the date and clock at the top, the user's picture (SDDM's `userModel` icon, only from a folder root
  writes: AccountsService's icons or SDDM's faces, `Strings.pictureUrl`; never `~/.face.icon`, which the user controls and
  which, as a FIFO, would block the greeter for every user: opus review of c5b02369; else the initials) and name,
  the password field, the error line; the user choice when there is more than one user; Restart and Shut Down (SDDM's
  `canReboot`/`canPowerOff`) at the bottom; the session pop-up, which selects "Grassfield (uwsm)" first, as Omarchy's theme
  does (its logic: the first session whose name contains "uwsm"), else SDDM's last session.
- Tokens only: colours, sizes and fonts come from `Grassfield.Ui`'s `Tokens` (the lock screen's `lock.*` and
  `color.dark.*` values), so the login and the lock are one design.
- If the theme cannot load (a QML error, the module missing), SDDM falls back to its embedded theme (VERIFY on the owner's
  machine: SDDM 0.21's greeter loads its built-in theme when the configured one has no valid `Main.qml`; a QML error at run
  time is the case to check), so a login is always possible; and the Omarchy theme is one revert command away.

### 3. The Plymouth theme (the mark on the ground)
- Plymouth's own `two-step` module (C code shipped by Plymouth), no script: the theme is a `.plymouth` file of key-value
  settings and PNG images. The disk-password prompt, its bullets and its keyboard handling are the module's; the theme
  supplies only the background colour (the default artwork's ground, `session.ground` `#2F6D5F`), the mark (white, the
  symbolic mark `grassfield-logo-full.svg` tinted as the shell tints it, the drawing unchanged), the entry box, the bullet,
  the lock glyph, the prompt's box (transparent) and a small throbber, all drawn here. `lock.png`, `box.png`, `entry.png`
  and `bullet.png` are what two-step needs to draw at all (without one, plymouthd shows its text view: safe for the
  prompt, but the theme is dead; VERIFY with `plymouthd --debug`).
- Fallback (the condition): Plymouth itself falls back to its text splash when a theme fails to load (a missing module,
  an unreadable image), and Esc switches to the text view at any time; the disk password is also asked on the console
  when Plymouth is not running. The owner's guide makes the first boot with the theme a test of exactly that: press Esc
  at the password prompt and see the text prompt, type the password there once. VERIFY on the owner's machine (this
  container has no Plymouth, no initramfs, no LUKS).
- The mark at boot: Plymouth reads PNG images only, so the mark is rendered at build from its file (112 px, its black fill
  drawn white, the drawing unchanged), where the session's places draw the file itself at run time (the use rule proposed
  with IQ-B1: "only the file's own path, at run time"). IQ-L1 C (« a Plymouth theme with the mark ») makes the boot screen a
  place of the mark; the owner confirmed the white build-time render on 2026-10-31 (« Oui, marque blanche », legal E41), and
  `tests/ci/login_themes.py` holds that nothing but the fill changes.
- Activation is the owner's: `plymouth-set-default-theme grassfield` and Omarchy's own initramfs rebuild (the guide asks
  to read Omarchy's refresh script for the exact command on that install; VERIFY), and the revert to Omarchy's theme the
  same way.

### 4. R12 for both themes
| Risk | SDDM | Plymouth |
|---|---|---|
| Authentication | SDDM's PAM service, untouched; the theme only calls `sddm.login` | the module's prompt, handed to systemd's cryptsetup by Plymouth; the theme draws images |
| Code that runs | QML in `sddm-greeter` as the `sddm` user, no process, no network, no file | none (a config file and PNGs; no script) |
| A broken theme | SDDM's embedded theme (VERIFY) | Plymouth's text splash; Esc; the console |
| Root steps | owner only (one drop-in, written by the owner) | owner only (set the theme, rebuild the initramfs) |
| Revert | delete the drop-in | set Omarchy's theme back, rebuild |

### 5. Tests
- `tests/ci/login_themes.py` (static; `--selftest` plants mutants): the SDDM theme uses no process, network, file or log
  call (`Process`, `XMLHttpRequest`, `Qt.openUrlExternally`, `console.*` on the password, `FileView`, `Loader` of a URL
  outside the theme), hands the password only to `sddm.login` and clears it; `metadata.desktop` is a Qt 6 theme; the
  `.plymouth` file names the `two-step` module, an image directory under `/usr/share/plymouth/themes/grassfield`, the
  ground as its background, and every image it needs is in the package; no `Script` module.
- An offscreen render of `Main.qml` with a stand-in `sddm`, `userModel` and `sessionModel` (the layout, the session picked,
  the password cleared after a failed login).
- `tests/ci/qml_literals.py` scans the theme (tokens only); `grassfield-login-check` knows it (the session it selects first)
  and `tests/shell/login_session.sh` checks that; `tests/unit/tst_loginstrings.qml` checks `Strings.js` (the picture only
  from the two root-written folders, the session selected first, the initials, the words).
- After the opus review of c5b02369 (PASS, three MINORs, two NITs, all fixed): `box.png`; the static test also refuses
  every other way to the typed text (`getText`, `displayText`, a computed member, an alias of the field or of `sddm`, an
  assigned `echoMode` or `source`, key handlers) and any picture URL but `Strings.pictureUrl`'s (53 mutants); the guide
  reads `/etc/sddm.conf` last and gives a recovery that needs no theme (`plymouth.enable=0` from Limine's editor).
  Counter-review of b5ad82fa: PASS; its NITs: no walk of the object tree (`children`, `data`, `resources`,
  `activeFocusItem`, `childAt`) and no `.text` read but the field's (58 mutants), and `Strings.pictureUrl` takes SDDM's
  icon as a path or as a `file://` URL (VERIFY which one SDDM gives: either shows the picture now).
- NOT VERIFIED here (owner, real machine): the SDDM theme in `sddm-greeter-qt6` (a log out, a wrong password, Restart and
  Shut Down), its fallback; the Plymouth theme at boot with the disk password, Esc to the text prompt, the revert.

## Alternatives rejected
- A Plymouth `script` theme (more freedom, but a script that fails can leave the screen without a prompt: the module's
  prompt is safer).
- Drawing the artwork in Plymouth (no QML there; a pre-rendered picture would be a large image in the initramfs for a few
  seconds of boot): the ground and the mark only.
- Activating the themes from the package (a pacman hook or an install script): root steps are the owner's, by rule.

## Consequences
- One new package and two new directories under `packaging/` (`sddm/theme`, `plymouth`), justified by this step.
- `docs/owner-setup/login-boot-themes.md`: the owner's commands, the first-boot test and the reverts.
- Legal: `docs/legal/visual-review.md` gains the login and boot screens (the macOS login window's layout, own drawings, the
  owner's mark).
