#!/usr/bin/env bash
# The "grassfield" Qt platform-theme plugin (ADR-0054), loaded by a real Qt application on a private bus and a Broadway display:
#   A  theme (tests/fixtures/qt-theme-probe, offscreen, GTK 3 on Broadway, a scratch GTK settings file naming a font no system has,
#      "Zzz Probe"):
#      A1 QT_QPA_PLATFORMTHEME=gtk3 (Omarchy's value): the reference palette, font and colour scheme; GTK's own chooser
#      A2 xdgdesktopportal with no plugin: Qt's generic base (Fusion, "Sans Serif"): the look this ADR must not give the session
#      A3 the plugin loaded by QPluginLoader: Qt's gtk3 theme (palette, text colour, font of A1) with QT_QPA_PLATFORMTHEME=
#         xdgdesktopportal; nothing, and GTK never touched, with any other value, none or an empty one
#      A4 the plugin with no display for GTK: never a crash or a hang
#   B  file chooser, offscreen, the real xdg-desktop-portal frontend and the real Grassfield backend (offscreen, answering its panel
#      by the dev hook) on the private bus: the portal theme's QFileDialog helper is the portal's and the probe.s
#      QFileDialog::getExistingDirectory reaches the backend (a panel is shown); x-d-p-gtk (a stand-in) receives nothing. Under gtk3
#      Qt's GTK 3 chooser draws in-process and the backend sees no call (the reason of the amendment of Q3).
#   D  the shell's start: a Qt process under a portal frontend that never answers, with gtk3 pinned (as the units do) and with the portal theme (timed).
#   C  the Wayland integration, as in the session, only with a nested session of this tree (just nested-up; slot rule): the portal
#      theme asks the plugin for XDG_CURRENT_DESKTOP's first item ("grassfield"): the look of gtk3 and the portal's dialog; with
#      another first item (Hyprland) the generic base; QFileDialog reaches the backend. (Offscreen's theme names do not include
#      the desktop's, which is why A and B cannot show it.)
# Needs dbus-daemon, broadwayd, python3 with PyGObject, /usr/lib/xdg-desktop-portal, cmake, g++, Qt 6 with private headers, GTK 3,
# KDE Frameworks 6 for the backend (apps/portal/build-direct.sh); SKIPs without them. Never the owner's bus or display.
# Run it bare (a sandbox refuses the sockets).
set -uo pipefail
root=$(git -C "$(dirname "$0")" rev-parse --show-toplevel)
tmp=$(mktemp -d "${GRASSFIELD_TEST_TMP:-${TMPDIR:-/tmp}}/qt-platform-theme.XXXXXX")
. "$root/tests/integration/portal-bus.sh"
bw_pid=""
stop_all() { stop_bus; [[ -n $bw_pid ]] && kill "$bw_pid" 2>/dev/null; wait 2>/dev/null; rm -rf "$tmp"; }
trap stop_all EXIT
trap 'exit 130' INT
trap 'exit 143' TERM
fail=0
check() { if "$@"; then echo "PASS: $desc"; else echo "FAIL: $desc"; fail=1; fi; }
skip() { echo "SKIP: qt_platform_theme: $1"; exit "$fail"; }

for tool in dbus-daemon broadwayd python3 cmake g++ pkg-config; do command -v "$tool" >/dev/null || skip "needs $tool"; done
frontend=/usr/lib/xdg-desktop-portal
[[ -x $frontend ]] || skip "needs xdg-desktop-portal ($frontend)"
[[ -e /usr/lib/qt6/plugins/platformthemes/libqgtk3.so && -e /usr/lib/qt6/plugins/platformthemes/libqxdgdesktopportal.so ]] || skip "needs Qt's gtk3 and xdgdesktopportal platform themes"
python3 -I -c 'import gi; gi.require_version("Gio", "2.0")' 2>/dev/null || skip "needs PyGObject"
[[ -d /usr/include/KF6/KIOCore ]] || skip "needs KDE Frameworks 6 to build the backend"

# --- builds ------------------------------------------------------------------------------------------------------------------
build=$root/.dev/qt-platform-theme-build
if ! { cmake -S "$root/packaging/qt-platform-theme" -B "$build" -G Ninja -DCMAKE_BUILD_TYPE=Release -DCMAKE_INSTALL_PREFIX=/usr >"$tmp/cmake.log" 2>&1 \
  && cmake --build "$build" >>"$tmp/cmake.log" 2>&1; }; then tail -n 20 "$tmp/cmake.log"; echo "FAIL: the plugin builds"; exit 1; fi
mkdir -p "$tmp/plugins/platformthemes"
cp "$build/libgrassfield-qt-theme.so" "$tmp/plugins/platformthemes/"
"$root/tests/fixtures/build.sh" qt-theme-probe >"$tmp/probe.log" 2>&1 || { tail -n 20 "$tmp/probe.log"; echo "FAIL: the probe builds"; exit 1; }
probe=$root/.dev/build/qt-theme-probe
"$root/apps/portal/build-direct.sh" >"$tmp/backend.log" 2>&1 || { tail -n 20 "$tmp/backend.log"; echo "FAIL: the backend builds"; exit 1; }
backend=$root/.dev/build/grassfield-portal
"$root/ui/i18n/build-direct.sh" >"$tmp/i18n.log" 2>&1 || { tail -n 20 "$tmp/i18n.log"; echo "FAIL: the Grassfield.I18n plugin builds"; exit 1; }
desc="the plugin is a Qt platform-theme plugin keyed grassfield"
check bash -c 'strings "$1" | grep -q "org.qt-project.Qt.QPA.QPlatformThemeFactoryInterface" && strings "$1" | grep -q "grassfield"' _ "$tmp/plugins/platformthemes/libgrassfield-qt-theme.so"

# --- the scene: a private bus, the frontend, the backend, a Broadway display for GTK ------------------------------------------------
d=$tmp/scene
mkdir -p "$d/services" "$d/home/.config/gtk-3.0" "$d/home/Documents" "$d/run" "$d/cfg" "$d/xdg" "$d/state" "$d/config"
chmod 700 "$d/run"
printf '[Settings]\ngtk-font-name=Zzz Probe 13\n' >"$d/home/.config/gtk-3.0/settings.ini"
echo hello >"$d/home/Documents/a.txt"
cp -r "$root/packaging/xdg/." "$d/xdg/"
disp=27
env -i PATH="$PATH" HOME="$d/home" XDG_RUNTIME_DIR="$d/run" broadwayd -a 127.0.0.1 ":$disp" >"$d/broadway.log" 2>&1 &
bw_pid=$!
disown "$bw_pid"
sleep 1
kill -0 "$bw_pid" 2>/dev/null || skip "broadwayd cannot start here ($(head -n 2 "$d/broadway.log" | tr '\n' ' '))"
cat >"$d/gtk.sh" <<E
#!/bin/sh
export GF_TEST_BUS=1 GF_TEST_BUS_DIR=$d DBUS_SESSION_BUS_ADDRESS="\$(head -n 1 $d/bus.address)"
exec python3 -I $root/tests/fixtures/fake-portal-backend.py gtk --log $d/gtk.log
E
cat >"$d/backend.sh" <<E
#!/bin/sh
echo started >>$d/backend.starts
exec env -i PATH="\$PATH" HOME=$d/home XDG_RUNTIME_DIR=$d/run DBUS_SESSION_BUS_ADDRESS="\$(head -n 1 $d/bus.address)" GF_TEST_BUS=1 GF_TEST_BUS_DIR=$d GRASSFIELD_DEV=1 GRASSFIELD_CONFIG_HOME=$d/config GRASSFIELD_STATE_HOME=$d/state QT_QPA_PLATFORM=offscreen QT_FORCE_STDERR_LOGGING=1 QML_IMPORT_PATH=$root/ui:$root/.dev/build/qml GRASSFIELD_FILES_QML=$root/apps/files/qml GRASSFIELD_PORTAL_TEST_ANSWER=accept GRASSFIELD_PORTAL_IDLE_MS=5000 $backend >>$d/backend.log 2>&1
E
printf '[D-BUS Service]\nName=org.freedesktop.impl.portal.desktop.gtk\nExec=%s/gtk.sh\n' "$d" >"$d/services/gtk.service"
printf '[D-BUS Service]\nName=org.freedesktop.impl.portal.desktop.grassfield\nExec=%s/backend.sh\n' "$d" >"$d/services/grassfield.service"
chmod 755 "$d"/*.sh
start_bus "$d" || { echo "FAIL: a private bus starts: $(head -n 1 "$d/bus.log")"; exit 1; }
env -i PATH="$PATH" HOME="$d/home" XDG_CONFIG_HOME="$d/cfg" XDG_DATA_HOME="$d/home/.local/share" XDG_RUNTIME_DIR="$d/run" \
  XDG_DATA_DIRS="$d/xdg:/usr/share" XDG_CURRENT_DESKTOP=Hyprland DBUS_SESSION_BUS_ADDRESS="$bus" "$frontend" -v -r >"$d/frontend.log" 2>&1 &
frontend_pid=$!
wait_until 15 owned org.freedesktop.portal.Desktop || { tail -n 5 "$d/frontend.log"; echo "FAIL: the frontend owns its name"; exit 1; }

# probe <extra env...> -- <args>: the probe on the scene, offscreen, GTK on Broadway. The caller's `theme` and `desktop` set the Qt
# variables; stdout and stderr go to $d/probe.out and $d/probe.err, the status to $rc.
rc=0
run_probe() {
  local envs=()
  while (($#)) && [[ $1 != -- ]]; do envs+=("$1"); shift
  done
  shift
  env -i PATH="$PATH" HOME="$d/home" XDG_RUNTIME_DIR="$d/run" DBUS_SESSION_BUS_ADDRESS="$bus" QT_QPA_PLATFORM=offscreen NO_AT_BRIDGE=1 \
    QT_FORCE_STDERR_LOGGING=1 "QT_LOGGING_RULES=qt.core.plugin.loader=true;qt.core.plugin.factoryloader=true;qt.qpa.theme*=true" "${envs[@]}" timeout "${probe_timeout:-40}" "$probe" "$@" >"$d/probe.out" 2>"$d/probe.err"
  rc=$?
}
val() { sed -n "s/^$1=//p" "$d/probe.out" | head -n 1; }
gdk=(GDK_BACKEND=broadway "BROADWAY_DISPLAY=:$disp")
desktop=Grassfield:Hyprland

# A1 -------------------------------------------------------------------------------------------------------------------------
run_probe "${gdk[@]}" QT_QPA_PLATFORMTHEME=gtk3 XDG_CURRENT_DESKTOP=$desktop --
ref_window=$(val window) ref_text=$(val text) ref_base=$(val base) ref_font=$(val font) ref_scheme=$(val color-scheme)
desc="A1 gtk3 (the reference): the GTK settings reach Qt (font 'Zzz Probe'), the process ends 0 [rc $rc, theme $(val theme), font $ref_font, window $ref_window]"
check bash -c '[[ $1 == 0 && $2 == "Zzz Probe" && -n $3 ]]' _ "$rc" "$ref_font" "$ref_window"
desc="A1 gtk3: Qt's GTK 3 theme builds GTK's chooser in-process (helper class [$(val file-dialog-helper)])"
check bash -c '[[ $1 == QGtk3FileDialogHelper ]]' _ "$(val file-dialog-helper)"

# A2 -------------------------------------------------------------------------------------------------------------------------
run_probe "${gdk[@]}" QT_QPA_PLATFORMTHEME=xdgdesktopportal XDG_CURRENT_DESKTOP=$desktop --
desc="A2 xdgdesktopportal with no plugin: Qt's generic base, the GTK font is lost (the look the plugin exists to keep) [theme $(val theme), font $(val font), window $(val window)]"
check bash -c '[[ $1 == QXdgDesktopPortalTheme && $2 != "Zzz Probe" ]]' _ "$(val theme)" "$(val font)"

# A3 -------------------------------------------------------------------------------------------------------------------------
# The plugin loaded by QPluginLoader (the probe's --theme-plugin mode) and asked for "grassfield", as Qt's portal theme does: with
# QT_QPA_PLATFORMTHEME=xdgdesktopportal it returns Qt's gtk3 theme (the palette, text colour and font of A1's reference); with any
# other value, or none, it returns nothing and GTK is never touched (Qt appends the platform's theme names after the variable, so on
# Wayland every Qt process of the session asks for "grassfield").
plug=$tmp/plugins/platformthemes/libgrassfield-qt-theme.so
run_probe "${gdk[@]}" QT_QPA_PLATFORMTHEME=xdgdesktopportal XDG_CURRENT_DESKTOP=$desktop -- --theme-plugin "$plug"
desc="A3 xdgdesktopportal: the plugin returns a theme whose palette, text colour and font are gtk3's [rc $rc, created $(val created): $(val font) $(val window) $(val text); A1: $ref_font $ref_window $ref_text]"
check bash -c '[[ $1 == 0 && $2 == 1 && $3 == "$4" && $5 == "$6" && $7 == "$8" ]]' _ "$rc" "$(val created)" "$(val font)" "$ref_font" "$(val window)" "$ref_window" "$(val text)" "$ref_text"
desc="A3 ... and it declines any other key [other=$(val other)]"
check bash -c '[[ $1 == 0 ]]' _ "$(val other)"
desc="A3 ... without a warning [$(grep -c 'did not load' "$d/probe.err") line(s)]"
check bash -c '! grep -q "did not load" "$1"' _ "$d/probe.err"
for v in unset gtk3 qt6ct kde none xdgdesktopportal2 "xdgdesktopportal:gtk3" empty; do
  case $v in
    unset) run_probe "${gdk[@]}" XDG_CURRENT_DESKTOP=$desktop -- --theme-plugin "$plug" ;;
    empty) run_probe "${gdk[@]}" QT_QPA_PLATFORMTHEME= XDG_CURRENT_DESKTOP=$desktop -- --theme-plugin "$plug" ;;
    *) run_probe "${gdk[@]}" "QT_QPA_PLATFORMTHEME=$v" XDG_CURRENT_DESKTOP=$desktop -- --theme-plugin "$plug" ;;
  esac
  desc="A3 QT_QPA_PLATFORMTHEME=$v: the plugin returns nothing and GTK is not initialised [rc $rc, created $(val created), $(grep -ci 'Gtk-\|Gdk-' "$d/probe.err") GTK line(s) on stderr]"
  check bash -c '[[ $1 == 0 && $2 == 0 ]] && ! grep -qi "Gtk-\|Gdk-" "$3"' _ "$rc" "$(val created)" "$d/probe.err"
done

# A4 -------------------------------------------------------------------------------------------------------------------------
run_probe GDK_BACKEND=broadway BROADWAY_DISPLAY=:98 QT_QPA_PLATFORMTHEME=xdgdesktopportal XDG_CURRENT_DESKTOP=$desktop -- --theme-plugin "$plug"
desc="A4 no display for GTK (what Qt's own gtk3 theme does without one): the process ends or goes on, never a crash or a hang [rc $rc, created $(val created)]"
check bash -c '[[ $1 -lt 124 ]]' _ "$rc"

# B --------------------------------------------------------------------------------------------------------------------------
# The portal's file dialog on the private bus (offscreen: Qt's generic base; the dialog is the portal theme's own).
desc="B the frontend routes FileChooser to the Grassfield backend"
check grep -q "Using grassfield.portal for org.freedesktop.impl.portal.FileChooser" "$d/frontend.log"
run_probe "${gdk[@]}" QT_QPA_PLATFORMTHEME=xdgdesktopportal XDG_CURRENT_DESKTOP=$desktop --
desc="B xdgdesktopportal: the file dialog helper a QFileDialog gets is the portal's [$(val file-dialog-helper)]"
check bash -c '[[ $1 == QXdgDesktopPortalFileDialog ]]' _ "$(val file-dialog-helper)"
run_probe "${gdk[@]}" QT_QPA_PLATFORMTHEME=xdgdesktopportal XDG_CURRENT_DESKTOP=$desktop -- --dialog
panels=$(grep -c 'panel shown' "$d/backend.log" 2>/dev/null)
desc="B QFileDialog: the Grassfield backend was started by D-Bus activation and showed a panel [$panels panel(s), starts $(wc -l <"$d/backend.starts" 2>/dev/null)]"
check bash -c '[[ $1 -ge 1 ]]' _ "${panels:-0}"
desc="B ... the application got an answer, not a timeout or a crash [rc $rc, $(tr '\n' ' ' <"$d/probe.out")]"
check bash -c '[[ $1 == 0 ]] && grep -q "^chosen=" "$2" && ! grep -q "chosen=TIMEOUT" "$2"' _ "$rc" "$d/probe.out"
desc="B ... and x-d-p-gtk received no FileChooser call [$(wc -l <"$d/gtk.log" 2>/dev/null || echo 0) line(s)]"
check bash -c '! grep -q "FileChooser" "$1" 2>/dev/null' _ "$d/gtk.log"
before=$panels
probe_timeout=6 run_probe "${gdk[@]}" QT_QPA_PLATFORMTHEME=gtk3 XDG_CURRENT_DESKTOP=$desktop GTK_USE_PORTAL=0 -- --dialog
after=$(grep -c 'panel shown' "$d/backend.log" 2>/dev/null)
desc="B under gtk3 (Omarchy's value) a QFileDialog never reaches the backend, GTK's chooser opens in-process (panels $before -> $after, rc $rc)"
check bash -c '[[ $1 == $2 ]]' _ "$before" "$after"

# C --------------------------------------------------------------------------------------------------------------------------
# The Wayland integration, as in the session: only with a nested session of this tree (just nested-up; slot rule), through
# scripts/dev/isolated.sh. The portal theme there asks the plugin for the session's name (XDG_CURRENT_DESKTOP's first item).
nested_sock=$(cat "$root/.dev/nested.wayland" 2>/dev/null)
section_c() {
wprobe() { # wprobe <extra env...> -- <args>: the probe on the nested Wayland socket, on this scene's bus (never the owner's)
  local envs=()
  while (($#)) && [[ $1 != -- ]]; do envs+=("$1"); shift
  done
  shift
  "$root/scripts/dev/isolated.sh" --name qtpt env -u GRASSFIELD_SESSION -u XDG_SESSION_DESKTOP -u DESKTOP_SESSION -u GDK_BACKEND \
    "DBUS_SESSION_BUS_ADDRESS=$bus" "WAYLAND_DISPLAY=$nested_sock" QT_QPA_PLATFORM=wayland NO_AT_BRIDGE=1 "${envs[@]}" \
    timeout "${probe_timeout:-40}" "$probe" "$@" >"$d/probe.out" 2>"$d/probe.err"
  rc=$?
}
wprobe QT_QPA_PLATFORMTHEME=gtk3 XDG_CURRENT_DESKTOP=$desktop --
w_ref=$(val window) w_font=$(val font) w_text=$(val text)
desc="C1 Wayland, gtk3 (the reference) [rc $rc: $(val theme) $w_font $w_ref $w_text]"
check bash -c '[[ $1 == 0 && $2 == QGtk3Theme ]]' _ "$rc" "$(val theme)"
wprobe QT_QPA_PLATFORMTHEME=xdgdesktopportal XDG_CURRENT_DESKTOP=$desktop --
desc="C2 Wayland, xdgdesktopportal without the plugin: Qt's generic base (what the plugin prevents) [$(val font) $(val window)]"
check bash -c '[[ $1 != "$2" ]]' _ "$(val window)" "$w_ref"
wprobe "QT_PLUGIN_PATH=$tmp/plugins" QT_QPA_PLATFORMTHEME=xdgdesktopportal XDG_CURRENT_DESKTOP=$desktop --
desc="C3 Wayland, with the plugin: the palette, font and text colour of gtk3 [$(val font) $(val window) $(val text); gtk3: $w_font $w_ref $w_text]"
check bash -c '[[ $1 == "$2" && $3 == "$4" && $5 == "$6" ]]' _ "$(val window)" "$w_ref" "$(val font)" "$w_font" "$(val text)" "$w_text"
desc="C3 ... under Qt's portal theme, whose dialog is the portal's [theme $(val theme), helper $(val file-dialog-helper)]"
check bash -c '[[ $1 == QXdgDesktopPortalTheme && $2 == QXdgDesktopPortalFileDialog ]]' _ "$(val theme)" "$(val file-dialog-helper)"
wprobe "QT_PLUGIN_PATH=$tmp/plugins" QT_QPA_PLATFORMTHEME=xdgdesktopportal XDG_CURRENT_DESKTOP=Hyprland --
desc="C4 first item Hyprland (the Omarchy session, a nested dev session): the plugin is not asked for, the generic base serves [$(val font) $(val window)]"
check bash -c '[[ $1 != "$2" ]]' _ "$(val window)" "$w_ref"
before=$(grep -c 'panel shown' "$d/backend.log" 2>/dev/null)
wprobe "QT_PLUGIN_PATH=$tmp/plugins" QT_QPA_PLATFORMTHEME=xdgdesktopportal XDG_CURRENT_DESKTOP=$desktop -- --dialog
after=$(grep -c 'panel shown' "$d/backend.log" 2>/dev/null)
desc="C5 Wayland, with the plugin: QFileDialog reaches the Grassfield backend (panels $before -> $after) and the application is answered [rc $rc, $(tr '\n' ' ' <"$d/probe.out")]"
check bash -c '[[ $3 -gt $2 && $1 == 0 ]] && grep -q "^chosen=" "$4" && ! grep -q TIMEOUT "$4"' _ "$rc" "$before" "$after" "$d/probe.out"
}
if [[ -n $nested_sock && -S ${XDG_RUNTIME_DIR:-/run/user/$(id -u)}/$nested_sock ]]; then
  section_c
else
  echo "SKIP: qt_platform_theme: section C needs the nested session (just nested-up): the Wayland integration is not covered by this run"
fi

# D --------------------------------------------------------------------------------------------------------------------------
# A Qt GUI process under a portal frontend that owns its name and never answers (ADR-0054 D-2: why the shell and the security
# process pin gtk3 in their units): Qt's portal theme waits for the portal's reply at start, the pinned value does not. Both
# starts are timed (offscreen, the probe with no argument).
stop_bus
# broadwayd ends (it aborts) when the clients of the earlier sections are gone: a fresh one for this section.
disp=29
env -i PATH="$PATH" HOME="$d/home" XDG_RUNTIME_DIR="$d/run" broadwayd -a 127.0.0.1 ":$disp" >"$d/broadway2.log" 2>&1 &
bw_pid=$!
disown "$bw_pid"
sleep 1
gdk=(GDK_BACKEND=broadway "BROADWAY_DISPLAY=:$disp")
sd=$tmp/silent
mkdir -p "$sd/services"
start_bus "$sd" || { echo "FAIL: a private bus starts: $(head -n 1 "$sd/bus.log")"; exit 1; }
GF_TEST_BUS=1 GF_TEST_BUS_DIR=$sd DBUS_SESSION_BUS_ADDRESS=$bus python3 -I "$root/tests/fixtures/fake-portal-backend.py" silent-frontend >"$sd/frontend.log" 2>&1 &
frontend_pid=$!
wait_until 10 owned org.freedesktop.portal.Desktop || { echo "FAIL: the silent frontend owns its name"; exit 1; }
timed() { # timed <variable> env...: the probe's start, in whole seconds
  local t0=$SECONDS
  probe_timeout=60 run_probe "${@:2}" --
  printf -v "$1" '%s' "$((SECONDS - t0))"
}
timed pinned_s "${gdk[@]}" QT_QPA_PLATFORMTHEME=gtk3 XDG_CURRENT_DESKTOP=$desktop
desc="D the unit's pinned gtk3 starts at once under a frontend that never answers [${pinned_s} s, rc $rc, broadwayd alive: $(kill -0 "$bw_pid" 2>/dev/null && echo yes || echo no); $(grep -v "Detected locale\|qt.core" "$d/probe.err" | tail -n 3 | tr '\n' ' ')]"
check bash -c '[[ $1 -le 5 && $2 == 0 ]]' _ "$pinned_s" "$rc"
timed portal_s "${gdk[@]}" QT_QPA_PLATFORMTHEME=xdgdesktopportal XDG_CURRENT_DESKTOP=$desktop
echo "INFO: D xdgdesktopportal under the same frontend: ${portal_s} s (rc $rc): the apps accept a wait, the shell and the security process must not"
stop_bus
exit "$fail"
