# ADR-0054: Qt apps and LibreOffice use Grassfield's Open and Save panels
Status: Proposed (2026-11-08), applied provisionally (owner rule of 2026-10-28), awaiting the owner's ratification · Date:
2026-11-08 · Decider: owner (ratify), integrator (merge) · Number: 0054 · Amends: owner decision Q3 of ADR-0035 (2026-10-27,
"Qt keeps `gtk3`")

## Context

Two owner decisions of 2026-11-08, both required before 1.0.0: Qt apps show Grassfield's Open and Save panels (the
FileChooser backend Grassfield ships) instead of GTK 3's chooser; LibreOffice uses its Qt VCL plugin in the Grassfield session
only, so that it gets those panels and the global menus.

What is true today (read and measured 2026-11-08; the earlier audit is in `docs/specs/system-dialogs.md` section 1, "Which
callers reach the panel"):
- Omarchy's `envs.lua` (`/usr/share/omarchy/default/hypr/envs.lua:14`) sets `QT_QPA_PLATFORMTHEME=gtk3`. Q3 kept it: Qt apps
  take the GTK palette, font, colour scheme and icons, and follow the Grassfield appearance through GTK (ADR-0003 `font-name`,
  ADR-0017 icons, ADR-0035 D-8). The reasons are in ADR-0035 (the "Not done" list of D-8) and ADR-0017 (Q-B).
- Qt's gtk3 theme builds `QGtk3FileDialogHelper`, a `GtkFileChooserDialog` in the app's own process. No portal call is made;
  `GTK_USE_PORTAL=1` does not apply to it.
- Qt 6.12's `xdgdesktopportal` theme (`libqxdgdesktopportal.so`) sends `QFileDialog` to the portal
  (`QXdgDesktopPortalFileDialog`). It takes its base theme not from `QT_QPA_PLATFORMTHEME` but from `XDG_CURRENT_DESKTOP`'s items,
  lower-cased, through the platform theme factory. The session's value is `Grassfield:Hyprland` (`config/hypr/session.lua`), so the
  names asked for are `grassfield` and `hyprland`; none is a Qt theme, so the base is the generic one: Fusion's light
  palette and "Sans Serif 9" instead of the GTK look (measured again by `tests/integration/qt_platform_theme.sh` A2).
- LibreOffice (`libreoffice-fresh` 26.8.1 here) ships `libvclplug_gtk3lo`, `gtk4lo`, `kf6lo`, `qt6lo` and `genlo` in
  `/usr/lib/libreoffice/program`. Its GTK 3 plugin builds its own chooser; the Qt 6 plugin uses `QFileDialog`, so it follows the
  Qt platform theme. It also registers its menus through Qt's platform menu bar, which the session's global menus read.
- The portal frontend's 25 s start at login, which made a first portal call from any client fail, was fixed by PR #20
  (ADR-0041 I-4); a Qt app's first `QFileDialog` no longer times out.

## Options, ranked by risk (lowest first)

| # | Option | Look | Chooser | Risk |
|---|---|---|---|---|
| 1 | Keep `gtk3` (Q3 as it was) | GTK | GTK 3's, in process | none, and the owner's requirement is not met |
| 2 | **A platform-theme plugin keyed `grassfield`, under `QT_QPA_PLATFORMTHEME=xdgdesktopportal`** (chosen) | GTK (gtk3 base) | the portal's | one small plugin on a private API, guarded (see D-3, D-4) |
| 3 | `xdgdesktopportal` alone | Fusion, "Sans Serif 9" | the portal's | no new code, the look is lost: rejected, the reason Q3 kept gtk3 |
| 4 | A `QPlatformTheme` subclass of Grassfield's own (palette, font, scheme, icons from Grassfield's settings) | Grassfield's, exactly | the portal's | the largest private surface (every `themeHint`, `palette`, `font` slot), a second place where the appearance is decided; not needed now |
| 5 | Patch or wrap the dialogs per app (kdialog shim, `QT_QPA_PLATFORMTHEME` per desktop file, an interposer) | unchanged | partial | fragile, per-app, and an interposer is never acceptable in a session that holds the lock screen |
| 6 | Run Qt apps through qt6ct or KDE's platform theme | theirs | KDE's or Qt's | new dependencies, replaces the GTK look |

Option 2 is the prototype of `docs/specs/system-dialogs.md` (measured then, built now).

## Decision

### D-1 The plugin
`packaging/qt-platform-theme/` (C++20, Qt 6 Core and Gui; `Qt6::GuiPrivate` for QPA): one `QPlatformThemePlugin` whose metadata key
is `grassfield`. `create("grassfield")` returns what Qt's own factory returns for `gtk3` (`QPlatformThemeFactory::create`), so the
base theme of Qt's portal theme is Qt's gtk3 theme: the palette, the font, the colour scheme and the icon theme the session had
under `gtk3`, unchanged. It adds nothing else: no appearance code of its own. It lives under `packaging/` and not in `apps/` or
`bridges/`: it is session glue installed into Qt's plugin directory, not an app or a bridge. It is installed as
`/usr/lib/qt6/plugins/platformthemes/libgrassfield-qt-theme.so` (Qt's `platformthemes` directory, which is where Qt 6.12 looks)
with `/usr/share/grassfield/qt-platform-theme/qt-version`, the Qt release it was built with. The PKGBUILD builds and installs it
into `grassfield-desktop`, `scripts/dev/check-cmake.sh` configures it, `just check` covers it.

### D-2 The session
`config/hypr/session.lua` (Grassfield session only; the Omarchy session never loads it) calls `config/hypr/grassfield/qttheme.lua`,
which decides `QT_QPA_PLATFORMTHEME`: `xdgdesktopportal` when the plugin is installed and stamped for the major.minor of the
installed Qt, `gtk3` (Omarchy's value, left as it is) otherwise, with the reason printed to the journal (`grassfield: Qt platform
theme: gtk3 kept: ...`). The plugin's key relies on the first item of `XDG_CURRENT_DESKTOP` being `Grassfield`, which
`session.lua` sets just before. Hyprland imports the compositor's environment into the systemd user manager and D-Bus
activation, so every process of the session sees the value, the shell and the security process included. Qt's portal theme makes a
blocking portal call when a Qt process starts, the same wait as `GTK_USE_PORTAL` (gate P5, ADR-0035 D-4): a slow portal would
delay the shell and the lock screen's restart after a crash. So every Grassfield unit that runs a Qt GUI process keeps its value
from before this ADR: `grassfield-shell.service` and `grassfield-security.service` pin `QT_QPA_PLATFORMTHEME=gtk3`
(`Environment=`, which wins over the manager's), and the portal backend and the settings backend keep
`UnsetEnvironment=GTK_USE_PORTAL QT_QPA_PLATFORMTHEME` (they must never ask themselves for a dialog; grassfield-portal also clears it
in its own `main`). The other units run QtCore programs, which load no platform theme. `tests/shell/qt_platform_theme.sh` finds
every unit that runs a Qt GUI process (`qs`, and the apps whose `main.cpp` makes a `QGuiApplication` or `QApplication`) and fails
if one neither pins nor clears. Every app the shell starts is its child, and `uwsm app` (its default is a
systemd scope, `-t scope`) runs the command in its caller's environment, not the manager's, so an app would inherit the shell's pin and
never get the portal theme. The session's choice therefore travels in a second variable: `session.lua` sets
`GRASSFIELD_APPS_QT_QPA_PLATFORMTHEME` next to `QT_QPA_PLATFORMTHEME` (only when the portal theme is chosen), `autostart.lua`'s
`uwsm finalize` list names it so that the systemd user manager hands it to the shell, and `Apps.launchEnvironment()` (and
`ownAppEnvironment()`, for Settings and Glance) gives `QT_QPA_PLATFORMTHEME` back to every app the shell starts, as it already does
for `GTK_USE_PORTAL` (`AppLaunch.themeEnvironment`, exactly the value `xdgdesktopportal`; every launch path of the shell, Dock,
Launchpad, Search, Open With, document and folder opens, goes through `launchEnvironment()`). The Launchpad's call to the Store is a
Grassfield helper that sets its own theme, and the shell's helper tools (`qs ipc`, `grassfield-*`) keep the pin. With the variable
absent (the login guard fell back to gtk3, a dev session) apps keep the shell's value, which is gtk3 as before. Grassfield's own Qt apps (Files, Settings, Preview) use the portal for `QFileDialog`
too; those that draw their own panels (the QML panels of Files) are unchanged.

The plugin serves the portal theme only. Qt appends the platform's own theme names after `QT_QPA_PLATFORMTHEME` (on Wayland, the
`XDG_CURRENT_DESKTOP` items), so any Wayland Qt process of the session asks for `grassfield` whatever the variable says. `create()`
therefore returns nothing unless `QT_QPA_PLATFORMTHEME` is exactly `xdgdesktopportal`, before it touches GTK (a process with the
variable unset, or naming `qt6ct`, `kde` or `none`, never reaches the plugin's gtk3 path, and the login stamp check does not have
to cover it). Applications that bundle their own Qt (Flatpaks, AppImages, a vendor's private Qt) do not load this
plugin and lose the gtk3 look under their own platform theme; only apps on the system Qt get it.

### D-3 The ABI story
QPA (`qpa/qplatformtheme.h`, `qplatformthemefactory_p.h`) is private API: Qt promises nothing between minor releases, so the plugin
is rebuilt with every Qt minor release (6.12 to 6.13), never carried over.
- **The build.** It is built in the same PKGBUILD as the shell and the apps, in the same `build()`, so every Grassfield build
  compiles it against the Qt that is installed. `BUILD-DEPS` (ADR-0033 s3.4) already records `qt6-base`'s version for that build;
  the plugin adds no entry of its own.
- **The hold.** The hold pair (ADR-0041 step 2a option A, branch `feat/update-hold`) makes `grassfield-hold` depend on
  `qt6-base>=<major.minor>` and `qt6-base<<next minor>`: a system update cannot move Qt to the next minor under an installed
  Grassfield, it waits for the Grassfield build made for that minor. That covers the plugin with no change to the hold. When the
  owner lifts the hold (`grassfield-unhold`) the guard of D-4 is what remains.
- **The watch job.** `qt6-base` is in `grassfield-update-check`'s `TRACKED` list, and the rc-channel gate
  (`scripts/gates/rc-toolkit.sh`, ADR-0033 f, ADR-0041 step 2c) runs `scripts/dev/test.sh --layer data,logic,headless` on the
  channel's Qt: it runs `tests/shell/qt_platform_theme.sh` (the agreement of session, CMake and PKGBUILD), but does not build the
  plugin against that Qt. Adding the plugin's `cmake --build` to that gate's `plugin` step is the follow-up that makes a Qt minor
  visible one Omarchy cycle early; `scripts/gates/` is outside this change's scope, so it is listed as an open point, not done.
  `just check-cmake-build` builds it against the installed Qt.
- **The guard** is in D-4.

### D-4 Degradation: never a crash, never a silent loss of the look
1. Before login: `qttheme.lua` compares the stamp (Qt major.minor at build) with the installed Qt (`Qt6CoreConfigVersionImpl.cmake`,
   qt6-base's own file). Plugin missing, stamp missing or unreadable, Qt unreadable, or any difference of major.minor: the session
   keeps `gtk3`. Qt apps look as before and show GTK's chooser (the pre-ADR state); the reason is in the journal (`journalctl
   --user -b | grep "Qt platform theme"`). A patch release (6.12.0 to 6.12.3) is the same ABI and keeps the plugin.
2. At run time: if Qt rejects the plugin (its own version check), the app never sees it and the portal theme's base is the generic
   one (Fusion look, the portal's file dialog kept). If Qt's `gtk3` theme itself returns nothing, the plugin returns nothing too and
   writes `grassfield.platformtheme: Qt's gtk3 platform theme did not load; the base theme falls back to Qt's generic one` to the app's
   stderr (a Qt logging category, on by default for warnings): never silent. The one failure measured (A4): no GDK display, where Qt's
   own `gtk3` theme makes GTK print "cannot open display" and the process end with status 1. That is what `gtk3` does today, so it is
   no new risk, and a Qt app on the session's Wayland display always has one; the tests of the offscreen apps unset the variable.
   The login check also refuses a plugin file that is not a whole shared object (ELF magic, a minimum size).
3. The one case not caught: a plugin built for Qt N loaded by a Qt N' of the same major.minor whose private classes still differ.
   That does not happen within a minor release by Qt's own policy; the hold and the stamp rest on that policy.
4. Settings: nothing to show when all is well, and no new pane when the guard falls back: the journal line (1) is the record, and
   the compatibility check of Software Update (ADR-0033 U27) is what keeps a Qt minor from arriving under an installed Grassfield
   in the first place.

### D-5 LibreOffice
`packaging/uwsm/env-grassfield` sets `SAL_USE_VCLPLUGIN=qt6`, only when `libvclplug_qt6lo.so` exists (a named plugin LibreOffice
cannot find would otherwise be an error). That file is where it belongs: uwsm hands its variables to the systemd user manager and
D-Bus activation, which is the environment the Dock, Launchpad, Search and Open With start apps from (`shell/services/Apps.qml`),
and only the Grassfield session sources it (the Omarchy session never does). The compositor's own environment (`hl.env`) would not
have reached those launches. The variable is read by LibreOffice's VCL at start and chooses its toolkit plugin; it is not stored. No
file of the user's LibreOffice profile (`registrymodifications.xcu`, `~/.config/libreoffice`) is read or written, and a user who runs
`SAL_USE_VCLPLUGIN=gtk3 soffice` gets what they ask for. LibreOffice under `qt6` follows the Qt platform theme (D-2): the GTK look,
`QFileDialog` and, through Qt's platform menu bar, the global menus. Not verified here: that LibreOffice's Qt 6 plugin sends its
Open and Save dialogs to the portal (a headless LibreOffice opens no dialog), and its look and menus: owner-checked on the next
release. The Qt 6 plugin belongs to `libreoffice-fresh`, an optional package (ADR-0046 lists LibreOffice among the removable
preinstalls).

### D-6 Settings
No new setting. The behaviour is the session's, as the portal routing is (ADR-0035); there is no toggle between "Grassfield's
panels" and "GTK's chooser" for Qt apps, as there is none for GTK apps. The reason: one place decides how a file is chosen, and
macOS has no such toggle. Nothing in Settings changes. A user who wants Omarchy's behaviour for one app sets `QT_QPA_PLATFORMTHEME=gtk3` in its launcher.

### D-7 Tests
- `tests/shell/qt_platform_theme.sh` (logic layer, no display, runs in the suite): the choice of `qttheme.lua` in each case (same
  minor, other patch, newer and older minor, newer major, no plugin, no stamp, a garbled stamp, an unreadable Qt); the block of
  `session.lua` run with a stub of `hl.env` (`xdgdesktopportal` and `qt6` when installed; `gtk3` kept, with the reason, when not;
  a missing module); both variables set only in `session.lua`; no LibreOffice profile path; the session, the plugin's CMake
  and the PKGBUILD agree (file name, Qt's plugin directory against `qtpaths`, the stamp's path, the key against the first item of
  `XDG_CURRENT_DESKTOP`, `build()` and `package_grassfield-desktop`, `BUILD-DEPS`, `check-cmake.sh`).
- `tests/integration/qt_platform_theme.sh` (headless layer, bare: it needs sockets), on a private bus, a Broadway display for GTK 3
  and the real frontend and backend: a Qt probe (`tests/fixtures/qt-theme-probe`). A: the plugin asked for by name gives the palette,
  font and colour scheme of `gtk3` (a font no system has, set in a scratch GTK file); `xdgdesktopportal` alone gives the generic
  look; the plugin loaded by `QPluginLoader` returns the `gtk3` palette, text colour and font under `xdgdesktopportal` and nothing for
  any other value (unset, `gtk3`, `qt6ct`, `kde`, `none`, empty) with GTK never touched; no GTK display ends like `gtk3` does, never a
  crash or a hang. B: the portal theme's `QFileDialog` helper is the portal's and
  a `QFileDialog` reaches the Grassfield backend (a panel is shown, the application is answered) while x-d-p-gtk receives nothing;
  under `gtk3` the backend sees no call. C, with a nested session of this tree (Qt's Wayland integration, as in the session): the portal
  theme asks the plugin for the session's name by itself, so Qt gets the `gtk3` look and the portal's dialog; with Hyprland first the
  plugin is not asked. Measured finding: under the offscreen integration the portal theme's names do not include the desktop's, so
  offscreen only reaches the plugin by name (A3); the session case is C.
- D, in the same script: a Qt process under a portal frontend that owns its name and never answers starts at once with `gtk3` pinned
  (the units' value), and the same start with the portal theme is timed for comparison.
- Not covered here (the integrator's nested pass): a Qt app's Open panel drawn in the nested session at scale 1.25, LibreOffice's
  window and menus under `qt6`: visual NOT verified.

## Consequences
- Qt apps (OBS, Kdenlive, Grassfield's own) and LibreOffice get one file panel with the GTK apps and the browsers.
- A new plugin on a private API: rebuilt at every Qt minor (the hold, D-3), guarded at login (D-4.1) and at run time (D-4.2).
- The gtk3 base still needs GTK 3 in the app's process (already installed with `xdg-desktop-portal-gtk`); no new dependency.
- A bug in the plugin affects every Qt app that starts in the session, shell included (the shell stays on a generic base if it fails).
  The fallback paths above keep it to a look change, not a failure to start.
- `docs/specs/system-dialogs.md` "Which callers reach the panel" and ADR-0035's Q3 text are updated to point here.

## Revisit when
Qt ships a public way to choose the portal theme's base (a `QT_QPA_PLATFORMTHEME` list or an environment variable); Qt 6.13 or 7
changes the portal theme's base lookup; the owner asks for an appearance Grassfield decides itself (option 4).
