#!/usr/bin/env bash
# The Settings portal backend (ADR-0035 D-4, D-8, step 2b) with the real xdg-desktop-portal frontend.
# Static (always): the session's routing file lists only Settings (grassfield-settings, then gtk) and FileChooser, Access,
# AppChooser and Print (grassfield, then gtk: tests/integration/portal_filechooser.sh); the .portal file, the D-Bus
# service file and the unit name the same bus name and program; the unit is Type=dbus, restarts on failure, clears
# GTK_USE_PORTAL and QT_QPA_PLATFORMTHEME and is hardened; the shell's unit clears GTK_USE_PORTAL; env-grassfield, on scratch
# copies of its paths, puts the routing directory first in XDG_DATA_DIRS once (keeping the list, or the default), sets
# GTK_USE_PORTAL=1 and adds portals to GDK_DEBUG once (keeping its flags), and does nothing when the file is unreadable; the
# PKGBUILD builds and installs every piece.
# Runtime, on a private bus of the test's own (its own configuration and service directory, the frontend under env -i with a
# scratch HOME, XDG_CURRENT_DESKTOP=Hyprland and the package's routing directory first in XDG_DATA_DIRS; the backend started by
# D-Bus activation as a dev session reading a scratch grassfield.json; a stand-in for x-d-p-gtk; never the owner's bus):
#  1 ReadAll and ReadOne through the frontend: Grassfield's values win over gtk's (color-scheme, gtk-theme), gtk still
#    answers the keys Grassfield does not own (font-name), the accent colour is the token's, the namespace filter holds; the
#    frontend keeps the stock routing for every other interface; the backend stays within its memory budget (ADR-0035
#    decision 2b-11: 4 MB private, 20 MB resident with the shared libraries)
#  2 a change of grassfield.json reaches a client as SettingChanged, only for the keys that changed; when x-d-p-gtk signals
#    a dconf change of keys Grassfield owns, the client still ends with Grassfield's values (and gets gtk's own keys)
#  3 the backend killed: the frontend's next read starts it again by D-Bus activation and gets Grassfield's values, and the
#    new process signals the next change; killed again, a change made while it is down reaches the client as soon as it is
#    started again without any read (as systemd's Restart=on-failure starts it)
#  4 without the backend, the frontend answers from gtk alone, at once
#  4b a backend whose activation fails when the frontend starts is left out for the frontend's whole life, even once it
#    runs (xdg-desktop-portal 1.22.1 makes its proxies once): why the frontend's unit starts after it (decision 2b-14)
#  5 the backend starts, owning its name, with GTK_USE_PORTAL=1, QT_QPA_PLATFORMTHEME=gtk3 and a frontend that never answers
#  6 refused outside a Grassfield session, and as a dev run on a bus that is not a private test bus
#  7 on a headless Wayland compositor (Weston), with the variables env-grassfield sets: a GTK 3 app, a GTK 4 app and a
#    libadwaita app take their theme, colour scheme, contrast and accent from the portal, and follow a change of
#    grassfield.json (light, orange, Increase Contrast) within a second; a GTK 4 app without GDK_DEBUG=portals does not (why the session sets it). SKIP without weston or the GTK 3,
#    GTK 4 and libadwaita introspection data.
# Needs dbus-daemon, python3 with PyGObject, /usr/lib/xdg-desktop-portal, and g++ with the Qt 6 D-Bus headers (or
# GRASSFIELD_PORTAL_SETTINGS: a built backend); the runtime part SKIPs without them, and when libdbus cannot reach the bus.
# Scenario 7 also needs weston, GTK 3, GTK 4 and libadwaita with their introspection data, and SKIPs without them.
set -uo pipefail
root=$(git -C "$(dirname "$0")" rev-parse --show-toplevel)
tmp=$(mktemp -d "${GRASSFIELD_TEST_TMP:-${TMPDIR:-/tmp}}/portal-settings.XXXXXX")
# The private bus (start_bus, stop_bus, owned, start_service, wait_until), shared with portal_filechooser.sh.
. "$root/tests/integration/portal-bus.sh"
stop_all() { stop_bus; wait 2>/dev/null; rm -rf "$tmp"; }
trap stop_all EXIT
trap 'exit 130' INT
trap 'exit 143' TERM
fail=0
check() { if "$@"; then echo "PASS: $desc"; else echo "FAIL: $desc"; fail=1; fi; }
pk=$root/packaging
name=org.freedesktop.impl.portal.desktop.grassfield_settings
unit=$pk/systemd/grassfield-portal-settings.service

# --- static ------------------------------------------------------------------------------------------------------------
desc="the session's routing lists only Secret (gnome-keyring, as Omarchy 4.5.0), Settings, FileChooser, Access, AppChooser and Print (D-4, D-5, D-7): Grassfield first, then gtk"
check test "$(grep -v '^#' "$pk/xdg/xdg-desktop-portal/hyprland-portals.conf" | grep -v '^$' | tr '\n' ' ')" = \
  "[preferred] org.freedesktop.impl.portal.Secret=gnome-keyring org.freedesktop.impl.portal.Settings=grassfield-settings;gtk org.freedesktop.impl.portal.FileChooser=grassfield;gtk org.freedesktop.impl.portal.Access=grassfield;gtk org.freedesktop.impl.portal.AppChooser=grassfield;gtk org.freedesktop.impl.portal.Print=grassfield;gtk "
desc="the .portal file, the D-Bus service file and the unit name the same bus name and program"
check bash -c 'grep -qx "DBusName=$1" "$2" && grep -qx "Interfaces=org.freedesktop.impl.portal.Settings;" "$2" && grep -qx "Name=$1" "$3" &&
  grep -qx "Exec=/usr/lib/grassfield/grassfield-portal-settings" "$3" && grep -qx "SystemdService=grassfield-portal-settings.service" "$3" &&
  grep -qx "BusName=$1" "$4" && grep -qx "ExecStart=/usr/lib/grassfield/grassfield-portal-settings" "$4"' _ "$name" \
  "$pk/xdg/xdg-desktop-portal/portals/grassfield-settings.portal" "$pk/dbus/$name.service" "$unit"
desc="the unit: Type=dbus, restarts after 1 s, only in the Grassfield session, clears GTK_USE_PORTAL and QT_QPA_PLATFORMTHEME, hardened"
check bash -c 'for l in Type=dbus Restart=on-failure RestartSec=1 ConditionEnvironment=GRASSFIELD_SESSION=1 \
  "UnsetEnvironment=GTK_USE_PORTAL QT_QPA_PLATFORMTHEME" NoNewPrivileges=yes ProtectSystem=strict ProtectHome=read-only \
  PrivateNetwork=yes RestrictAddressFamilies=AF_UNIX; do grep -qx "$l" "$1" || { echo "missing: $l"; exit 1; }; done' _ "$unit"
desc="the shell's unit clears GTK_USE_PORTAL (its start never waits on the portal, gate P5)"
check grep -qx "UnsetEnvironment=GTK_USE_PORTAL" "$pk/systemd/grassfield-shell.service"
desc="the PKGBUILD builds and installs the backend, its unit, routing, .portal and service files, and the generated themes; the package depends on the portals and libcups"
check bash -c 'grep -q "cmake --install \"\$srcdir/portal-settings-build\"" "$1" && grep -q "for unit in .*portal-settings" "$1" &&
  grep -q "usr/share/grassfield/xdg/xdg-desktop-portal/hyprland-portals.conf" "$1" &&
  grep -q "usr/share/grassfield/xdg/xdg-desktop-portal/portals/grassfield-settings.portal" "$1" &&
  grep -q "usr/share/dbus-1/services/$2.service" "$1" && grep -q "gen-gtk-themes.py\" \"\$srcdir/gtk-themes\"" "$1" &&
  grep -q "\$pkgdir/usr/share/themes/" "$1" && grep -q "xdg-desktop-portal xdg-desktop-portal-gtk libcups[ )]" "$1"' _ "$pk/arch/PKGBUILD" "$name"

dropin=$pk/systemd/xdg-desktop-portal.service.d/10-grassfield.conf
desc="the frontend's unit only gains grassfield-portal-config before it starts (no ExecStart, Environment or other change of what the frontend and the apps it launches get)"
check bash -c 'grep -qx "ExecStartPre=-/usr/lib/grassfield/grassfield-portal-config" "$1" && ! grep -Eq "^(ExecStart|Environment|EnvironmentFile|PassEnvironment|UnsetEnvironment|WorkingDirectory)=" "$1" && [[ -x "$2" ]]' _ "$dropin" "$pk/bin/grassfield-portal-config"
desc="the session names Grassfield first in XDG_CURRENT_DESKTOP, after Omarchy's envs.lua, keeping Hyprland, and only in session.lua (the Omarchy session never loads it)"
check bash -c 'n=$(grep -n "require(\"grassfield.omarchy\")" "$1" | head -n 1 | cut -d: -f1); m=$(grep -n "^hl.env(\"XDG_CURRENT_DESKTOP\", \"Grassfield:Hyprland\")$" "$1" | cut -d: -f1); [[ -n $n && -n $m && $m -gt $n ]]' _ "$root/config/hypr/session.lua"
if command -v systemd-analyze >/dev/null && [[ -r /usr/lib/systemd/user/xdg-desktop-portal.service ]]; then
  # The drop-in beside a copy of the stock unit, as systemd reads them.
  mkdir -p "$tmp/units/xdg-desktop-portal.service.d"
  cp /usr/lib/systemd/user/xdg-desktop-portal.service "$tmp/units/"
  cp "$dropin" "$tmp/units/xdg-desktop-portal.service.d/10-grassfield.conf"
  desc="systemd-analyze verify reads the unit with its drop-in without a warning about it"
  check bash -c '! systemd-analyze verify --user "$1/xdg-desktop-portal.service" 2>&1 | grep -qi "10-grassfield"' _ "$tmp/units"
fi

# The session's XDG_CURRENT_DESKTOP, read from session.lua; the real grassfield-portal-config, its path rewritten to a scratch copy.
session_desktop=$(sed -n 's/^hl\.env("XDG_CURRENT_DESKTOP", "\(.*\)")$/\1/p' "$root/config/hypr/session.lua")
sed "s|/usr/share/grassfield/xdg|$tmp/gf|g" "$pk/bin/grassfield-portal-config" >"$tmp/portal-config"
# The real env file, its paths rewritten to a scratch copy.
mkdir -p "$tmp/gf/xdg-desktop-portal"
sed "s|/usr/share/grassfield/xdg|$tmp/gf|g" "$pk/uwsm/env-grassfield" >"$tmp/env"
envof() { # envof [XDG_DATA_DIRS before] [twice] [GDK_DEBUG before]: "XDG_DATA_DIRS|GTK_USE_PORTAL|GDK_DEBUG" after sourcing
  env -i PATH="$PATH" ${1:+XDG_DATA_DIRS="$1"} ${3:+GDK_DEBUG="$3"} sh -c '. "$1"; [ "${2-}" = twice ] && . "$1"; printf "%s|%s|%s" "${XDG_DATA_DIRS-unset}" "${GTK_USE_PORTAL-unset}" "${GDK_DEBUG-unset}"' \
    _ "$tmp/env" "${2-}"
}
desc="env-grassfield: no routing file readable, nothing set"
check test "$(envof)" = "unset|unset|unset"
cp "$pk/xdg/xdg-desktop-portal/hyprland-portals.conf" "$tmp/gf/xdg-desktop-portal/"
desc="env-grassfield: the routing directory first, then the default data directories; GTK_USE_PORTAL=1, GDK_DEBUG=portals"
check test "$(envof)" = "$tmp/gf:/usr/local/share:/usr/share|1|portals"
desc="env-grassfield: an existing XDG_DATA_DIRS is kept after it, and sourced twice it appears once"
check test "$(envof /usr/share:/opt/share twice)" = "$tmp/gf:/usr/share:/opt/share|1|portals"
desc="env-grassfield: GDK_DEBUG keeps the flags it has, and gets portals once"
check test "$(envof "" twice "events" | cut -d'|' -f3)" = "events,portals"
desc="env-grassfield sets neither XDG_CONFIG_HOME nor XDG_CURRENT_DESKTOP (the portal routing needs no change of what apps inherit from it)"
check bash -c '[[ $(env -i PATH="$PATH" sh -c ". \"\$1\"; printf \"%s|%s\" \"\${XDG_CONFIG_HOME-unset}\" \"\${XDG_CURRENT_DESKTOP-unset}\"" _ "$1") == "unset|unset" ]]' _ "$tmp/env"
# The shell's unit clears GTK_USE_PORTAL for the shell (gate P5); the apps it starts get it back (review of step 2b).
desc="env-grassfield records GRASSFIELD_APPS_GTK_USE_PORTAL=1 for the shell, and the shell gives GTK_USE_PORTAL back to every app it starts (Settings and Glance included)"
check bash -c '[[ $(env -i PATH="$PATH" sh -c ". \"\$1\"; echo \"\${GRASSFIELD_APPS_GTK_USE_PORTAL-unset}\"" _ "$1") == 1 ]] &&
  ! grep -q GRASSFIELD_APPS_GTK_USE_PORTAL "$2" &&
  grep -qF "AppLaunch.portalEnvironment(Mode.appsGtkPortal)" "$3" &&
  grep -qF "readonly property bool appsGtkPortal: RunMode.appsGtkPortal(Quickshell.env(\"GRASSFIELD_APPS_GTK_USE_PORTAL\"))" "$5" &&
  grep -qF "const session = AppLaunch.mergeEnvironment(portalEnvironment, themeEnvironment);" "$3" &&
  grep -qF "AppLaunch.mergeEnvironment(devSession ? AppLaunch.isolatedEnvironment(appsHome) : ({}), session)" "$3" &&
  grep -qF "AppLaunch.mergeEnvironment(AppLaunch.mergeEnvironment(portalEnvironment, themeEnvironment), Pointer.launchEnvironment())" "$3" &&
  grep -qF "launcher.environment = Apps.ownAppEnvironment();" "$4/SettingsApp.qml" &&
  grep -qF "launcher.environment = Apps.ownAppEnvironment();" "$4/GlanceApp.qml" &&
  ! grep -rn "environment = Pointer.launchEnvironment()" "$4/.."' _ \
  "$tmp/env" "$pk/systemd/grassfield-shell.service" "$root/shell/services/Apps.qml" "$root/shell/services" "$root/shell/lib/Mode.qml"

# --- runtime -----------------------------------------------------------------------------------------------------------
frontend=/usr/lib/xdg-desktop-portal
for tool in dbus-daemon python3; do
  command -v "$tool" >/dev/null || { echo "SKIP: portal_settings needs $tool (runtime part)"; exit "$fail"; }
done
[[ -x $frontend ]] || { echo "SKIP: portal_settings needs xdg-desktop-portal ($frontend; runtime part)"; exit "$fail"; }
python3 -I -c 'import gi; gi.require_version("Gio", "2.0")' 2>/dev/null || { echo "SKIP: portal_settings needs PyGObject"; exit "$fail"; }
backend=${GRASSFIELD_PORTAL_SETTINGS:-}
if [[ -z $backend ]]; then
  command -v g++ >/dev/null && pkg-config --exists Qt6DBus 2>/dev/null || { echo "SKIP: portal_settings needs g++ and the Qt 6 D-Bus headers"; exit "$fail"; }
  "$root/apps/portal-settings/build-direct.sh" --out "$tmp/bin" >"$tmp/build.log" 2>&1 || { cat "$tmp/build.log"; echo "FAIL: the backend builds"; exit 1; }
  backend=$tmp/bin/grassfield-portal-settings
fi
client=$root/tests/fixtures/portal-client.py
fakes=$root/tests/fixtures/fake-portal-backend.py

call() { DBUS_SESSION_BUS_ADDRESS=$bus python3 -I "$client" "$@"; }
settings() { # settings <dir> <json>: grassfield.json, replaced atomically as the Settings app writes it
  printf '%s\n' "$2" >"$1/config/grassfield.json.new" && mv -f "$1/config/grassfield.json.new" "$1/config/grassfield.json"
}
# One scenario: a fresh bus whose service directory starts the Grassfield backend (when GRASSFIELD is yes) and the gtk
# stand-in on demand, then the real frontend. Sets d.
scenario() { # scenario <name> <yes|no|broken> [variant]: broken = the backend's activation fails when the frontend starts.
  # Variants, all with the user's own hyprland-portals.conf that Omarchy 4.5.0's migration 1788261467 installs (its bytes are
  # compared after): omarchy45 = the Grassfield session (XDG_CURRENT_DESKTOP of session.lua; the frontend's unit runs
  # grassfield-portal-config first); omarchy45-bare = no link and "Hyprland", the Omarchy session as it is, and what the Grassfield
  # session was before this fix (the control); omarchy45-leftover = "Hyprland" with the link a Grassfield session left in the
  # user's directory (the Omarchy session after one); omarchy45-dangling = the Grassfield session with a link whose target is gone
  # (Grassfield removed). Without a variant: the Grassfield session and no user file. Sets d, desktop, user_conf.
  d=$tmp/$1
  mkdir -p "$d/services" "$d/config" "$d/home" "$d/run" "$d/cfg" "$d/xdg"
  chmod 700 "$d/run"
  desktop=$session_desktop
  user_conf=$d/cfg/xdg-desktop-portal/hyprland-portals.conf
  if [[ ${3:-} == omarchy45* ]]; then
    mkdir -p "$d/cfg/xdg-desktop-portal"
    printf '[preferred]\ndefault=hyprland;gtk\norg.freedesktop.impl.portal.Secret=gnome-keyring\n' >"$user_conf"
    cp "$user_conf" "$d/omarchy-hyprland-portals.conf.orig"
  fi
  case ${3:-} in
    omarchy45) GRASSFIELD_SESSION=1 XDG_CONFIG_HOME=$d/cfg HOME=$d/home sh "$tmp/portal-config" ;;
    omarchy45-bare) desktop=Hyprland ;;
    omarchy45-leftover)
      desktop=Hyprland
      GRASSFIELD_SESSION=1 XDG_CONFIG_HOME=$d/cfg HOME=$d/home sh "$tmp/portal-config"
      ;;
    omarchy45-dangling) ln -s "$tmp/gone/hyprland-portals.conf" "$d/cfg/xdg-desktop-portal/grassfield-portals.conf" ;;
  esac
  cp -r "$pk/xdg/." "$d/xdg/"
  # xdg-desktop-portal-hyprland's .portal file (as Omarchy installs it) for the interfaces the routing leaves to the stock rules
  # (default=hyprland;gtk: Screenshot, ScreenCast): the routing checked in 1 and 4c then does not depend on what this machine has
  # installed. Its name is never owned on the private bus (the real one is not either); only the frontend's choice is read.
  printf '[portal]\nDBusName=org.freedesktop.impl.portal.desktop.hyprland\nInterfaces=org.freedesktop.impl.portal.Screenshot;org.freedesktop.impl.portal.ScreenCast;org.freedesktop.impl.portal.GlobalShortcuts;\nUseIn=wlroots;Hyprland;sway;Wayfire;river\n' \
    >"$d/xdg/xdg-desktop-portal/portals/hyprland.portal"
  printf '#!/bin/sh\necho $$ >%s/gtk.pid\nexport GF_TEST_BUS=1 GF_TEST_BUS_DIR=%s DBUS_SESSION_BUS_ADDRESS="$(head -n 1 %s/bus.address)"\nexec python3 -I %s gtk --log %s/gtk.log\n' \
    "$d" "$d" "$d" "$fakes" "$d" >"$d/gtk.sh"
  printf '[D-BUS Service]\nName=org.freedesktop.impl.portal.desktop.gtk\nExec=%s/gtk.sh\n' "$d" >"$d/services/gtk.service"
  if [[ $2 != no ]]; then
    printf '#!/bin/sh\necho started >>%s/backend.starts\necho $$ >%s/backend.pid\nexec env -i PATH="$PATH" HOME=%s/home DBUS_SESSION_BUS_ADDRESS="$(head -n 1 %s/bus.address)" GF_TEST_BUS=1 GF_TEST_BUS_DIR=%s GRASSFIELD_DEV=1 GRASSFIELD_CONFIG_HOME=%s/config GRASSFIELD_PORTAL_SETTINGS_CLOCK=12:00 %s\n' \
      "$d" "$d" "$d" "$d" "$d" "$d" "$backend" >"$d/backend.sh"
    printf '[D-BUS Service]\nName=%s\nExec=%s/backend.sh\n' "$name" "$d" >"$d/services/grassfield.service"
    [[ $2 == broken ]] && printf '[D-BUS Service]\nName=%s\nExec=/bin/false\n' "$name" >"$d/services/grassfield.service"
  fi
  chmod 755 "$d"/*.sh
  settings "$d" '{"appearance": "dark"}'
  start_bus "$d" || { echo "bus: $(head -n 1 "$d/bus.log")"; return 1; }
  env -i PATH="$PATH" HOME="$d/home" XDG_CONFIG_HOME="$d/cfg" XDG_DATA_HOME="$d/home/.local/share" XDG_RUNTIME_DIR="$d/run" \
    XDG_DATA_DIRS="$d/xdg:/usr/share" XDG_CURRENT_DESKTOP=$desktop DBUS_SESSION_BUS_ADDRESS="$bus" \
    "$frontend" -v -r >"$d/frontend.log" 2>&1 &
  frontend_pid=$!
  wait_until 10 owned org.freedesktop.portal.Desktop
}
# The backend this scenario started (its PID from backend.sh), killed; never any other process of that name.
kill_backend() { kill -KILL "$(cat "$d/backend.pid")" 2>/dev/null; wait_until 5 unowned "$name"; }
value() { python3 -I -c 'import json,sys; d=json.loads(sys.stdin.read()); print(json.dumps(eval(sys.argv[1], {}, {"d": d})))' "$1"; }

# Preflight: libdbus reaches a private bus.
mkdir -p "$tmp/pre/services"
if ! start_bus "$tmp/pre"; then desc="a private bus starts [$(head -n 1 "$tmp/pre/bus.log")]"; check false; exit 1; fi
if ! pre=$(DBUS_SESSION_BUS_ADDRESS=$bus python3 -I -c 'from gi.repository import Gio; Gio.bus_get_sync(Gio.BusType.SESSION)' 2>&1); then
  echo "SKIP: portal_settings: this environment gives no way to a private bus (${pre%%$'\n'*})"; exit "$fail"
fi
stop_bus

# 1 --------------------------------------------------------------------------------------------------------------------
scenario values yes || exit 1
all=$(call read-all)
got=$(value '[d["org.freedesktop.appearance"]["color-scheme"], d["org.gnome.desktop.interface"]["gtk-theme"], d["org.gnome.desktop.interface"]["font-name"]]' <<<"$all")
desc="1 ReadAll through the frontend: Grassfield's color-scheme and gtk-theme win over gtk's, gtk answers font-name [$got]"
check test "$got" = '[1, "Grassfield-multicolor-dark", "Inter 10"]'
got=$(value '[d["org.freedesktop.appearance"][k] for k in ("accent-color", "contrast", "reduced-motion")]' <<<"$all")
desc="1 the accent colour is the token's (multicolor, dark: #4FB36B), with contrast and reduced-motion 0 [$got]"
check test "$got" = '[[0.3098, 0.702, 0.4196], 0, 0]'
desc="1 the backend was started by D-Bus activation at the frontend's first read"
check test "$(wc -l <"$d/backend.starts" 2>/dev/null)" = 1
got="$(call read-one org.freedesktop.appearance color-scheme) $(call read-all 'org.gnome.*' | value 'sorted(d)')"
desc="1 ReadOne and the namespace filter [$got]"
check test "$got" = '1 ["org.gnome.desktop.interface"]'
got=$(grep -oE "Using [a-z-]+\.portal for org\.freedesktop\.impl\.portal\.[A-Za-z]+ \(((default|interface specific) )?config\)" "$d/frontend.log" | sort -u | tr '\n' ';')
desc="1 the session's file routes Settings, FileChooser, Access, AppChooser and Print only: every other interface keeps the stock routing (Screenshot) [$got]"
check bash -c '[[ $1 == *"Using grassfield-settings.portal for org.freedesktop.impl.portal.Settings (config)"* &&
  $1 == *"Using grassfield.portal for org.freedesktop.impl.portal.FileChooser (interface specific config)"* &&
  $1 == *"Using grassfield.portal for org.freedesktop.impl.portal.Access (interface specific config)"* &&
  $1 == *"Using grassfield.portal for org.freedesktop.impl.portal.AppChooser (interface specific config)"* &&
  $1 == *"Using grassfield.portal for org.freedesktop.impl.portal.Print (interface specific config)"* &&
  $1 == *"org.freedesktop.impl.portal.Screenshot (default config)"* &&
  $(grep -oE "[A-Za-z]+ \((interface specific )?config\)" <<<"$1" | grep -v "^Secret " | sort -u | tr "\n" " ") == "Access (interface specific config) AppChooser (interface specific config) FileChooser (interface specific config) Print (interface specific config) Settings (config) " ]]' _ "$got"
read -r rss anon < <(awk '/^VmRSS:/ { r = $2 } /^RssAnon:/ { a = $2 } END { print r, a }' "/proc/$(cat "$d/backend.pid")/status" 2>/dev/null)
desc="1 the backend's memory is within its budget (private <= 4 MB, resident <= 20 MB) [private ${anon:-?} kB, resident ${rss:-?} kB]"
check bash -c '[[ -n $1 && -n $2 && $1 -le 4096 && $2 -le 20480 ]]' _ "$anon" "$rss"

# 2 --------------------------------------------------------------------------------------------------------------------
: >"$d/signals"
DBUS_SESSION_BUS_ADDRESS=$bus python3 -I "$client" watch "$d/signals" 30 >"$d/watch.out" 2>&1 &
watcher=$!
wait_until 5 test -s "$d/watch.out"
settings "$d" '{"appearance": "light", "accent": {"color": "orange"}}'
wait_until 5 grep -q '"gtk-theme", "value": "Grassfield-orange"' "$d/signals"
sleep 0.5
keys=$(python3 -I -c 'import json,sys; print(" ".join(sorted("%s/%s" % (j["ns"].split(".")[-1], j["key"]) for j in map(json.loads, open(sys.argv[1])))))' "$d/signals")
desc="2 a change of grassfield.json reaches the client as SettingChanged, for the keys that changed only [$keys]"
check test "$keys" = "appearance/accent-color appearance/color-scheme interface/color-scheme interface/gtk-theme"
desc="2 the frontend then answers the new values [$(call read-one org.gnome.desktop.interface gtk-theme)]"
check test "$(call read-one org.gnome.desktop.interface gtk-theme)" = '"Grassfield-orange"'
# x-d-p-gtk signals a dconf change (a theme tool): the frontend passes it on, and the backend answers with its own values.
: >"$d/signals"
kill -USR1 "$(cat "$d/gtk.pid")"
wait_until 5 grep -q '"font-name"' "$d/signals"
sleep 0.5
got=$(python3 -I -c '
import json, sys
last = {}
for j in map(json.loads, open(sys.argv[1])):
    last[j["key"] if j["ns"].endswith("interface") or j["key"] != "color-scheme" else "appearance-color-scheme"] = j["value"]
print(json.dumps([last.get("gtk-theme"), last.get("appearance-color-scheme"), last.get("font-name")]))' "$d/signals")
desc="2 after x-d-p-gtk signals gtk-theme, color-scheme and font-name, the client ends with Grassfield's two and gtk's font [$got]"
check test "$got" = '["Grassfield-orange", 2, "Cantarell 11"]'
# ... x-d-p-gtk signalling the value Grassfield already has gets no answer (no theme reload for nothing).
: >"$d/signals"
kill -USR2 "$(cat "$d/gtk.pid")"
wait_until 5 grep -q '"gtk-theme"' "$d/signals"
sleep 0.5
desc="2 x-d-p-gtk signalling Grassfield's own value gets no answer: one gtk-theme signal [$(grep -c '"gtk-theme"' "$d/signals")]"
check test "$(grep -c '"gtk-theme"' "$d/signals")" = 1
# ... and a client that is not x-d-p-gtk, signalling on the backends' interface, gets none either (no relay, no loop).
: >"$d/signals"
DBUS_SESSION_BUS_ADDRESS=$bus python3 -I -c '
from gi.repository import Gio, GLib
c = Gio.bus_get_sync(Gio.BusType.SESSION)
for i in range(50):
    c.emit_signal(None, "/org/freedesktop/portal/desktop", "org.freedesktop.impl.portal.Settings", "SettingChanged",
                  GLib.Variant("(ssv)", ("org.gnome.desktop.interface", "gtk-theme", GLib.Variant("s", "Adwaita"))))
c.flush_sync(None)'
sleep 1
desc="2 50 signals from a client that is not x-d-p-gtk: nothing reaches the apps [$(wc -l <"$d/signals") signals]"
check test "$(wc -l <"$d/signals")" = 0

# 3 --------------------------------------------------------------------------------------------------------------------
kill_backend
got="$(call read-one org.gnome.desktop.interface gtk-theme) $(wc -l <"$d/backend.starts")"
desc="3 the backend killed: the frontend's next read starts it again and answers Grassfield's values [$got]"
check test "$got" = '"Grassfield-orange" 2'
: >"$d/signals"
settings "$d" '{"appearance": "light", "accent": {"color": "purple"}}'
desc="3 ... and the new process signals the next change to the client"
check wait_until 5 grep -q '"gtk-theme", "value": "Grassfield-purple"' "$d/signals"
kill_backend
: >"$d/signals"
settings "$d" '{"appearance": "light", "accent": {"color": "red"}}'
sleep 0.3
start_service "$name"
desc="3 killed again, a change made while it is down reaches the client once it starts, with no read [$(wc -l <"$d/backend.starts") starts]"
check wait_until 5 grep -q '"gtk-theme", "value": "Grassfield-red"' "$d/signals"
kill "$watcher" 2>/dev/null; wait "$watcher" 2>/dev/null
stop_bus

# 4 --------------------------------------------------------------------------------------------------------------------
scenario absent no || exit 1
start=$(date +%s%N)
theme=$(call read-one org.gnome.desktop.interface gtk-theme)
ms=$((($(date +%s%N) - start) / 1000000))
desc="4 without the backend the frontend answers from gtk alone, at once [$theme, $ms ms]"
check bash -c '[[ $1 == "\"Adwaita-dark\"" && $2 -lt 3000 ]]' _ "$theme" "$ms"
stop_bus

# 4b -------------------------------------------------------------------------------------------------------------------
scenario late broken || exit 1
first=$(call read-one org.gnome.desktop.interface gtk-theme)
# The backend can start now (its service file fixed, the bus told), and does.
printf '[D-BUS Service]\nName=%s\nExec=%s/backend.sh\n' "$name" "$d" >"$d/services/grassfield.service"
DBUS_SESSION_BUS_ADDRESS=$bus python3 -I -c '
from gi.repository import Gio
Gio.bus_get_sync(Gio.BusType.SESSION).call_sync("org.freedesktop.DBus", "/org/freedesktop/DBus", "org.freedesktop.DBus",
    "ReloadConfig", None, None, Gio.DBusCallFlags.NONE, 5000, None)'
start_service "$name"
wait_until 5 owned "$name"
later=$(call read-one org.gnome.desktop.interface gtk-theme)
desc="4b a backend not there when the frontend starts is left out for good, even once it runs [$first, then $later, owned $(has "$name"); $(grep -c 'Failed to create settings proxy' "$d/frontend.log") proxy failure]"
check bash -c '[[ $1 == "\"Adwaita-dark\"" && $2 == "\"Adwaita-dark\"" && $3 == True && $4 -ge 1 ]]' _ "$first" "$later" "$(has "$name")" \
  "$(grep -c 'Failed to create settings proxy' "$d/frontend.log")"
kill_backend
stop_bus
desc="4b ... so the frontend's unit wants the backend and starts after it (packaged drop-in), and the backend has no Requisite= that could fail first"
check bash -c 'grep -qx "Wants=grassfield-portal-settings.service" "$1" && grep -qx "After=grassfield-portal-settings.service" "$1" &&
  ! grep -q "^Requisite=" "$2" && grep -q "usr/lib/systemd/user/xdg-desktop-portal.service.d/10-grassfield.conf" "$3"' _ \
  "$pk/systemd/xdg-desktop-portal.service.d/10-grassfield.conf" "$unit" "$pk/arch/PKGBUILD"

# 4c ------------------------------------------------------------------------------------------------------------------
# Omarchy 4.5.0's migration writes ~/.config/xdg-desktop-portal/hyprland-portals.conf (default=hyprland;gtk): the frontend reads the
# user's directory first. The Grassfield session names Grassfield first in XDG_CURRENT_DESKTOP and the frontend's unit makes the
# user's grassfield-portals.conf link (grassfield-portal-config); nothing of the frontend's environment changes.
scenario shadow-control yes omarchy45-bare || exit 1
got=$(call read-one org.gnome.desktop.interface gtk-theme)
desc="4c control: the user's hyprland-portals.conf of Omarchy 4.5.0 wins over the session's routing when nothing prevents it [$got]"
check test "$got" = '"Adwaita-dark"'
stop_bus
scenario shadow-leftover yes omarchy45-leftover || exit 1
got=$(call read-one org.gnome.desktop.interface gtk-theme)
desc="4c the Omarchy session (XDG_CURRENT_DESKTOP=Hyprland) with the link a Grassfield session left behind: unchanged, the user's file still rules [$got]"
check test "$got" = '"Adwaita-dark"'
stop_bus
scenario shadow-dangling yes omarchy45-dangling || exit 1
got=$(call read-one org.gnome.desktop.interface gtk-theme)
desc="4c a dangling grassfield-portals.conf (Grassfield removed) is skipped: the frontend runs and the user's hyprland-portals.conf rules [$got]"
check test "$got" = '"Adwaita-dark"'
stop_bus
scenario shadow yes omarchy45 || exit 1
got=$(call read-one org.gnome.desktop.interface gtk-theme)
desc="4c in the Grassfield session ($session_desktop) with that file present, Settings still goes to Grassfield [$got]"
check test "$got" = '"Grassfield-multicolor-dark"'
got=$(grep -oE "Using [a-z-]+\.portal for org\.freedesktop\.impl\.portal\.[A-Za-z]+ \(((default|interface specific) )?config\)" "$d/frontend.log" | sort -u | tr '\n' ';')
desc="4c ... and so do FileChooser, Access, AppChooser and Print, Secret goes to gnome-keyring where its portal is installed, and every other interface (Screenshot, ScreenCast) keeps the stock routing [$got]"
check bash -c '[[ $1 == *"Using grassfield.portal for org.freedesktop.impl.portal.FileChooser"* && $1 == *"Using grassfield.portal for org.freedesktop.impl.portal.Access"* &&
  $1 == *"Using grassfield.portal for org.freedesktop.impl.portal.AppChooser"* && $1 == *"Using grassfield.portal for org.freedesktop.impl.portal.Print"* &&
  $1 == *"org.freedesktop.impl.portal.Screenshot (default config)"* &&
  ( ! -r /usr/share/xdg-desktop-portal/portals/gnome-keyring.portal || $1 == *"Using gnome-keyring.portal for org.freedesktop.impl.portal.Secret"* ) ]]' _ "$got"
desc="4c the link the session made points to the session's routing, and Omarchy's hyprland-portals.conf is byte for byte what the migration wrote"
check bash -c '[[ $(readlink "$1/cfg/xdg-desktop-portal/grassfield-portals.conf") == "$2/xdg-desktop-portal/hyprland-portals.conf" ]] && cmp -s "$1/cfg/xdg-desktop-portal/hyprland-portals.conf" "$1/omarchy-hyprland-portals.conf.orig" && [[ ! -L $1/cfg/xdg-desktop-portal/hyprland-portals.conf ]]' _ "$d" "$tmp/gf"
# What the frontend is given is what the session gave it, so is what the applications it launches (OpenURI, OpenFile,
# autostart files of the Background portal) inherit: the user's XDG_CONFIG_HOME, the session's XDG_CURRENT_DESKTOP, no extra variable.
fenv=$(tr '\0' '\n' <"/proc/$frontend_pid/environ" 2>/dev/null | sort | tr '\n' ' ')
desc="4c the frontend's environment is the session's: XDG_CONFIG_HOME stays the user's, XDG_CURRENT_DESKTOP is the session's, nothing Grassfield-specific is added [$fenv]"
check bash -c '[[ $1 == *" XDG_CONFIG_HOME=$2/cfg "* && $1 == *" XDG_CURRENT_DESKTOP=$3 "* && $1 != *GRASSFIELD_PORTAL* && $(tr " " "\n" <<<"$1" | grep -c .) == 8 ]]' _ " $fenv" "$d" "$session_desktop"
stop_bus
# grassfield-portal-config on its own: it only runs in the Grassfield session, never overwrites a file of the user's, and
# never touches Omarchy's hyprland-portals.conf.
pc() { # pc <dir> [env...]: runs the program with that configuration home
  local dir=$1
  shift
  env -i PATH="$PATH" HOME="$dir/home" XDG_CONFIG_HOME="$dir/cfg" "$@" sh "$tmp/portal-config"
  echo $?
}
t=$tmp/pc1 && mkdir -p "$t/cfg/xdg-desktop-portal" "$t/home"
printf 'omarchy\n' >"$t/cfg/xdg-desktop-portal/hyprland-portals.conf"
got=$(pc "$t")
desc="4c grassfield-portal-config does nothing outside the Grassfield session (no GRASSFIELD_SESSION=1) [$got]"
check bash -c '[[ $1 == 0 && ! -e $2/cfg/xdg-desktop-portal/grassfield-portals.conf && ! -L $2/cfg/xdg-desktop-portal/grassfield-portals.conf ]]' _ "$got" "$t"
got=$(pc "$t" GRASSFIELD_SESSION=1; pc "$t" GRASSFIELD_SESSION=1)
desc="4c in the Grassfield session it makes the link, twice the same, exit 0, and leaves Omarchy's file as it is [$got]"
check bash -c '[[ $1 == "0 0" && $(readlink "$2/cfg/xdg-desktop-portal/grassfield-portals.conf") == "$3/xdg-desktop-portal/hyprland-portals.conf" && $(cat "$2/cfg/xdg-desktop-portal/hyprland-portals.conf") == omarchy ]]' _ "$(tr '\n' ' ' <<<"$got" | sed 's/ $//')" "$t" "$tmp/gf"
t=$tmp/pc2 && mkdir -p "$t/cfg/xdg-desktop-portal" "$t/home"
printf 'mine\n' >"$t/cfg/xdg-desktop-portal/grassfield-portals.conf"
pc "$t" GRASSFIELD_SESSION=1 >/dev/null
desc="4c a grassfield-portals.conf that is the user's own file is kept"
check bash -c '[[ ! -L $1/cfg/xdg-desktop-portal/grassfield-portals.conf && $(cat "$1/cfg/xdg-desktop-portal/grassfield-portals.conf") == mine ]]' _ "$t"
t=$tmp/pc3 && mkdir -p "$t/cfg/xdg-desktop-portal" "$t/home"
ln -s /somewhere/else.conf "$t/cfg/xdg-desktop-portal/grassfield-portals.conf"
pc "$t" GRASSFIELD_SESSION=1 >/dev/null
desc="4c a link that is not one of ours is kept, and a link of ours to an older path is replaced"
t2=$tmp/pc4 && mkdir -p "$t2/cfg/xdg-desktop-portal" "$t2/home"
ln -s "$tmp/gf/old/hyprland-portals.conf" "$t2/cfg/xdg-desktop-portal/grassfield-portals.conf"
pc "$t2" GRASSFIELD_SESSION=1 >/dev/null
check bash -c '[[ $(readlink "$1/cfg/xdg-desktop-portal/grassfield-portals.conf") == /somewhere/else.conf && $(readlink "$2/cfg/xdg-desktop-portal/grassfield-portals.conf") == "$3/xdg-desktop-portal/hyprland-portals.conf" ]]' _ "$t" "$t2" "$tmp/gf"
t=$tmp/pc5 && mkdir -p "$t/home"
got=$(env -i PATH="$PATH" HOME="$t/home" XDG_CONFIG_HOME=relative GRASSFIELD_SESSION=1 sh "$tmp/portal-config"; echo $?; env -i PATH="$PATH" GRASSFIELD_SESSION=1 sh "$tmp/portal-config"; echo $?)
desc="4c a relative XDG_CONFIG_HOME, or no home at all, writes nothing and exits 0 [$(tr '\n' ' ' <<<"$got")]"
check bash -c '[[ $(tr "\n" " " <<<"$1") == "0 0 " && -z $(ls -A "$2/home") ]]' _ "$got" "$t"
t=$tmp/pc6 && mkdir -p "$t/home"
pc "$t" GRASSFIELD_SESSION=1 >/dev/null
desc="4c without an xdg-desktop-portal directory the program makes it (the migration may not have run), by HOME's .config when XDG_CONFIG_HOME is unset"
got=$(env -i PATH="$PATH" HOME="$t/home" GRASSFIELD_SESSION=1 sh "$tmp/portal-config"; readlink "$t/home/.config/xdg-desktop-portal/grassfield-portals.conf")
check test "$got" = "$tmp/gf/xdg-desktop-portal/hyprland-portals.conf"

# 5 --------------------------------------------------------------------------------------------------------------------
d=$tmp/silent
mkdir -p "$d/services" "$d/config" "$d/home"
start_bus "$d" || exit 1
setsid env -i PATH="$PATH" GF_TEST_BUS=1 GF_TEST_BUS_DIR="$d" DBUS_SESSION_BUS_ADDRESS="$bus" python3 -I "$fakes" silent-frontend >"$d/fake.log" 2>&1 &
wait_until 5 owned org.freedesktop.portal.Desktop
env -i PATH="$PATH" HOME="$d/home" DBUS_SESSION_BUS_ADDRESS="$bus" GF_TEST_BUS=1 GF_TEST_BUS_DIR="$d" GRASSFIELD_DEV=1 \
  GRASSFIELD_CONFIG_HOME="$d/config" GTK_USE_PORTAL=1 QT_QPA_PLATFORMTHEME=gtk3 timeout 20 "$backend" >"$d/backend.log" 2>&1 &
direct=$!
started=$(date +%s%N)
wait_until 5 owned "$name"
ms=$((($(date +%s%N) - started) / 1000000))
desc="5 with GTK_USE_PORTAL=1, QT_QPA_PLATFORMTHEME=gtk3 and a frontend that never answers, the backend owns its name at once [$ms ms]"
check test "$ms" -lt 3000
kill "$direct" 2>/dev/null; wait "$direct" 2>/dev/null
stop_bus

# 6 --------------------------------------------------------------------------------------------------------------------
out=$(env -i PATH="$PATH" HOME="$tmp" "$backend" 2>&1); rc=$?
desc="6 refused outside a Grassfield session (exit 2) [$rc: $out]"
check bash -c '[[ $1 == 2 && $2 == *"refused: not a Grassfield session"* ]]' _ "$rc" "$out"
for bad in "unix:path=/run/user/$(id -u)/bus" "unix:path=$tmp/x/../../run/user/$(id -u)/bus"; do
  out=$(env -i PATH="$PATH" HOME="$tmp" GRASSFIELD_DEV=1 GF_TEST_BUS=1 GF_TEST_BUS_DIR="$tmp/x" DBUS_SESSION_BUS_ADDRESS="$bad" \
    timeout 5 "$backend" 2>&1); rc=$?
  desc="6 a dev run on $bad (not under the test's directory) is refused (exit 2) [$rc: $out]"
  check bash -c '[[ $1 == 2 && $2 == *"refused: a dev session runs it only on a private test bus"* ]]' _ "$rc" "$out"
done

# 7 --------------------------------------------------------------------------------------------------------------------
typelib() { python3 -I -c 'import gi, importlib, sys; gi.require_version(sys.argv[1], sys.argv[2]); importlib.import_module("gi.repository." + sys.argv[1])' "$@" 2>/dev/null; }
if ! command -v weston >/dev/null || ! typelib Gtk 3.0 || ! typelib Gtk 4.0 || ! typelib Adw 1; then
  echo "SKIP: portal_settings: scenario 7 needs weston and the GTK 3, GTK 4 and libadwaita introspection data"
  exit "$fail"
fi
scenario live yes || exit 1
mkdir -p "$d/share/themes"
python3 -I "$root/ui/tools/gen-gtk-themes.py" "$d/share/themes" >/dev/null
env -i PATH="$PATH" HOME="$d/home" XDG_RUNTIME_DIR="$d/run" weston --backend=headless --socket=wl-portal-test --no-config \
  >"$d/weston.log" 2>&1 &
weston_pid=$!
wait_until 5 test -S "$d/run/wl-portal-test"
# What the session sets, from the real env-grassfield (the static part's scratch copy, routing file present).
IFS='|' read -r _ gtk_use_portal gdk_debug <<<"$(envof)"
toolkit() { # toolkit <3|4|adw> <log> [GDK_DEBUG]: a watcher on the Weston display, the test's bus and the generated themes
  env -i PATH="$PATH" HOME="$d/home" XDG_RUNTIME_DIR="$d/run" WAYLAND_DISPLAY=wl-portal-test GDK_BACKEND=wayland NO_AT_BRIDGE=1 \
    DBUS_SESSION_BUS_ADDRESS="$bus" XDG_DATA_DIRS="$d/share:/usr/share" GTK_USE_PORTAL="$gtk_use_portal" ${3:+GDK_DEBUG="$3"} \
    python3 -I "$root/tests/fixtures/toolkit-watch.py" "$1" 15 >"$2" 2>"$2.err" &
}
toolkit 3 "$d/gtk3" "$gdk_debug"
toolkit 4 "$d/gtk4" "$gdk_debug"
toolkit adw "$d/adw" "$gdk_debug"
toolkit 4 "$d/gtk4-plain"
wait_until 10 bash -c 'for f in gtk3 gtk4 adw gtk4-plain; do [[ -s $1/$f ]] || exit 1; done' _ "$d"
sleep 1
changed_at=$(date +%s.%N)
settings "$d" '{"appearance": "light", "accent": {"color": "orange"}, "accessibility": {"increaseContrast": true}}'
wait_until 5 bash -c 'grep -q orange-hc "$1/gtk3" && grep -q orange-hc "$1/gtk4" && grep -q "\"dark\": false, \"hc\": true, \"accent\": \"orange\"" "$1/adw"' _ "$d"
sleep 0.5
# "<first state> -> <last state> <seconds from the change to the last state>" (-1 when nothing changed)
states() { python3 -I -c '
import json, sys
lines = [json.loads(l) for l in open(sys.argv[1]) if l.strip()]
keys = [k for k in lines[0] if k != "at"]
state = lambda l: ",".join(str(l[k]) for k in keys)
print(state(lines[0]), "->", state(lines[-1]), "%.2f" % (lines[-1]["at"] - float(sys.argv[2]) if len(lines) > 1 else -1))' "$1" "$changed_at" 2>&1; }
prompt() { awk -v t="${1##* }" 'BEGIN { exit !(t >= 0 && t < 1) }'; }
got=$(states "$d/gtk3")
desc="7 a GTK 3 app (GTK_USE_PORTAL=$gtk_use_portal) takes the Grassfield theme from the portal and follows the change [$got]"
check bash -c '[[ $1 == "Grassfield-multicolor-dark -> Grassfield-orange-hc "* ]]' _ "$got"
desc="7 ... within a second of the change"; check prompt "$got"
got=$(states "$d/gtk4")
desc="7 a GTK 4 app (GDK_DEBUG=$gdk_debug) takes the theme and the colour scheme, and follows the change [$got]"
check bash -c '[[ $1 == "Grassfield-multicolor-dark,2 -> Grassfield-orange-hc,3 "* ]]' _ "$got"
desc="7 ... within a second of the change"; check prompt "$got"
got=$(states "$d/adw")
desc="7 a libadwaita app goes from dark with green (multicolor's nearest) to light, high contrast, orange [$got]"
check bash -c '[[ $1 == "True,False,green -> False,True,orange "* ]]' _ "$got"
desc="7 ... within a second of the change"; check prompt "$got"
got=$(states "$d/gtk4-plain")
desc="7 control: a GTK 4 app without GDK_DEBUG=portals does not take the theme from the portal [$got]"
check bash -c '[[ $1 != *Grassfield-* ]]' _ "$got"
# A restart of the backend (every value announced again, decision 2b-9) leaves each app as it was.
before=$(for f in gtk3 gtk4 adw; do states "$d/$f" | awk '{ print $3 }'; done | tr '\n' ' ')
lines=$(wc -l "$d/gtk3" "$d/gtk4" "$d/adw" | awk 'NR <= 3 { print $1 }' | tr '\n' ' ')
starts=$(wc -l <"$d/backend.starts")
kill_backend
start_service "$name"
sleep 1
desc="7 the backend was killed and started again [starts $starts -> $(wc -l <"$d/backend.starts"), owned $(has "$name")]"
check bash -c '[[ $2 -eq $(($1 + 1)) && $3 == True ]]' _ "$starts" "$(wc -l <"$d/backend.starts")" "$(has "$name")"
after=$(for f in gtk3 gtk4 adw; do states "$d/$f" | awk '{ print $3 }'; done | tr '\n' ' ')
desc="7 a restart of the backend (every value announced again) leaves the apps as they were [$after; lines GTK 3, GTK 4, libadwaita: $lines-> $(wc -l "$d/gtk3" "$d/gtk4" "$d/adw" | awk 'NR <= 3 { print $1 }' | tr '\n' ' ')]"
check test "$before" = "$after"
kill "$weston_pid" 2>/dev/null; wait "$weston_pid" 2>/dev/null
stop_bus

exit "$fail"
