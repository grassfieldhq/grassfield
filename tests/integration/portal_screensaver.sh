#!/usr/bin/env bash
# ADR-0041 I-4: the portal frontend started 25 s late after login. xdg-desktop-portal-gtk's ScreenSaver proxy (gdbus-codegen)
# asks org.freedesktop.DBus.Properties.GetAll of org.freedesktop.ScreenSaver while it starts; grassfield-menu-bridge owns that
# name and used to drop every call but Inhibit and UnInhibit without a reply, so x-d-p-gtk (and the frontend, which waits for
# its name) waited out D-Bus's 25 s method timeout. Not GTK_USE_PORTAL: x-d-p-gtk unsets it itself before gtk_init.
# Runtime, on a PRIVATE bus of the test's own (never the owner's), the real /usr/lib/xdg-desktop-portal frontend activating the
# real /usr/lib/xdg-desktop-portal-gtk on a Broadway display (no compositor needed):
#  1 an owner of org.freedesktop.ScreenSaver that drops the call (the old bridge's behaviour): the frontend owns its name
#    only after 20 s or more (the defect, measured)
#  2 the real bridge (built from this tree): the same start is ready in under 10 s (measured)
#  3 the bridge answers GetAll (empty a{sv}), Get (UnknownProperty), an unknown interface (UnknownInterface), an unknown
#    member (UnknownMethod); a call with NoReplyExpected gets no reply and the bridge keeps answering
# SKIPs without dbus-daemon, broadwayd, python3 with PyGObject, /usr/lib/xdg-desktop-portal, /usr/lib/xdg-desktop-portal-gtk
# or a bridge build. Usage: tests/integration/portal_screensaver.sh   Exit: 0 PASS or SKIP, 1 FAIL.
set -uo pipefail
root=$(git -C "$(dirname "$0")" rev-parse --show-toplevel)
fail=0
say() { printf '%s\n' "$*"; }
check() { local what=$1; shift; if "$@"; then say "  PASS $what"; else say "  FAIL $what"; fail=1; fi; }
skip() { say "SKIP: portal_screensaver: $*"; exit 0; }
for tool in dbus-daemon broadwayd python3; do command -v "$tool" >/dev/null || skip "needs $tool"; done
frontend=/usr/lib/xdg-desktop-portal
xdpg=/usr/lib/xdg-desktop-portal-gtk
[[ -x $frontend && -x $xdpg ]] || skip "needs $frontend and $xdpg"
python3 -I -c 'import gi; gi.require_version("Gio", "2.0")' 2>/dev/null || skip "needs PyGObject"
bridge=${GRASSFIELD_MENU_BRIDGE:-$root/.dev/build/grassfield-menu-bridge}
if [[ ! -x $bridge || $root/bridges/menu-bridge/src/DBusObjects.cpp -nt $bridge || $root/bridges/menu-bridge/src/ScreenSaver.cpp -nt $bridge ]]; then
  "$root/bridges/menu-bridge/build-direct.sh" >/dev/null 2>&1 || skip "the bridge does not build here"
fi
tmp=$(mktemp -d "${GRASSFIELD_TEST_TMP:-${TMPDIR:-/tmp}}/portal-ss.XXXXXX")
. "$root/tests/integration/portal-bus.sh"
extra_pids=()
stop_all() { stop_bus; for p in "${extra_pids[@]}"; do kill "$p" 2>/dev/null; done; wait 2>/dev/null; rm -rf "$tmp"; }
trap stop_all EXIT

# The owner of org.freedesktop.ScreenSaver that reproduces the old bridge: it owns the name and drops every method call.
cat >"$tmp/dropper.py" <<'PY'
import sys
from gi.repository import Gio, GLib
def filt(conn, msg, incoming):
    if incoming and msg.get_message_type() == Gio.DBusMessageType.METHOD_CALL \
            and msg.get_interface() not in ("org.freedesktop.DBus.Peer", "org.freedesktop.DBus.Introspectable"):
        return None
    return msg
c = Gio.bus_get_sync(Gio.BusType.SESSION)
c.add_filter(filt)
Gio.bus_own_name_on_connection(c, "org.freedesktop.ScreenSaver", Gio.BusNameOwnerFlags.NONE, None, None)
GLib.MainLoop().run()
PY

# measure <label> <dropper|bridge>: sets secs (seconds until the frontend owns org.freedesktop.portal.Desktop, 60 at most).
measure() {
  local label=$1 who=$2 d=$tmp/$1
  mkdir -p "$d/services" "$d/home" "$d/run"
  chmod 700 "$d/run"
  env -i PATH="$PATH" HOME="$d/home" XDG_RUNTIME_DIR="$d/run" broadwayd :7 >"$d/broadway.log" 2>&1 &
  extra_pids+=($!)
  # x-d-p-gtk with the session's own GTK_USE_PORTAL=1 (it unsets it itself before gtk_init).
  printf '#!/bin/sh\nexec env -i PATH="$PATH" HOME=%s XDG_RUNTIME_DIR=%s GDK_BACKEND=broadway BROADWAY_DISPLAY=:7 NO_AT_BRIDGE=1 GTK_USE_PORTAL=1 DBUS_SESSION_BUS_ADDRESS="$(head -n 1 %s/bus.address)" %s\n' \
    "$d/home" "$d/run" "$d" "$xdpg" >"$d/gtk.sh"
  chmod 755 "$d/gtk.sh"
  printf '[D-BUS Service]\nName=org.freedesktop.impl.portal.desktop.gtk\nExec=%s/gtk.sh\n' "$d" >"$d/services/gtk.service"
  start_bus "$d" || { say "  FAIL a private bus starts: $(head -n 1 "$d/bus.log")"; fail=1; return 1; }
  # GLib cannot reach a tcp bus under a socket-less sandbox and x-d-p-gtk then exits at once: the measurement needs a unix socket.
  [[ $bus == unix:* ]] || skip "needs a unix-socket private bus (portal-bus.sh fell back to tcp, a sandbox: run it bare)"
  sleep 1 # broadwayd's socket
  if [[ $who == dropper ]]; then
    env -i PATH="$PATH" HOME="$d/home" DBUS_SESSION_BUS_ADDRESS="$bus" python3 -I "$tmp/dropper.py" &
  else
    env -i PATH="$PATH" HOME="$d/home" XDG_RUNTIME_DIR="$d/run" DBUS_SESSION_BUS_ADDRESS="$bus" GRASSFIELD_DEV=1 \
      GRASSFIELD_MENU_BRIDGE_SOCKET="$d/run/bridge.sock" "$bridge" >"$d/bridge.log" 2>&1 </dev/null &
  fi
  extra_pids+=($!)
  wait_until 10 owned org.freedesktop.ScreenSaver || { say "  FAIL the ScreenSaver owner ($who) owns its name: $(tail -n 3 "$d/bridge.log" 2>/dev/null)"; fail=1; return 1; }
  local t0 t1
  t0=$(date +%s.%N)
  env -i PATH="$PATH" HOME="$d/home" XDG_RUNTIME_DIR="$d/run" XDG_DATA_DIRS=/usr/share XDG_CURRENT_DESKTOP=Hyprland \
    DBUS_SESSION_BUS_ADDRESS="$bus" "$frontend" -r >"$d/frontend.log" 2>&1 &
  frontend_pid=$!
  wait_until 60 owned org.freedesktop.portal.Desktop
  t1=$(date +%s.%N)
  secs=$(python3 -I -c 'import sys; print(round(float(sys.argv[2]) - float(sys.argv[1]), 1))' "$t0" "$t1")
}

say "[1] an owner that drops the call (the old bridge)"
if measure old dropper; then
  check "the frontend took 20 s or more to own its name [$secs s]" python3 -I -c 'import sys; sys.exit(not float(sys.argv[1]) >= 20)' "$secs"
fi
stop_bus

say "[2] the real bridge"
if measure fixed bridge; then
  check "the frontend owned its name in under 10 s [$secs s]" python3 -I -c 'import sys; sys.exit(not float(sys.argv[1]) < 10)' "$secs"

  say "[3] the bridge answers every call"
  probe() { DBUS_SESSION_BUS_ADDRESS=$bus python3 -I - "$@" <<'PY'
import sys
from gi.repository import Gio, GLib
what = sys.argv[1]
c = Gio.bus_get_sync(Gio.BusType.SESSION)
def call(iface, member, params, sig=None):
    try:
        r = c.call_sync("org.freedesktop.ScreenSaver", "/org/freedesktop/ScreenSaver", iface, member, params, None, Gio.DBusCallFlags.NONE, 3000, None)
        return "reply " + str(r.unpack())
    except GLib.Error as e:
        return "error " + Gio.DBusError.get_remote_error(e)
if what == "getall":
    print(call("org.freedesktop.DBus.Properties", "GetAll", GLib.Variant("(s)", ("org.freedesktop.ScreenSaver",))))
elif what == "get":
    print(call("org.freedesktop.DBus.Properties", "Get", GLib.Variant("(ss)", ("org.freedesktop.ScreenSaver", "X"))))
elif what == "iface":
    print(call("org.example.Other", "Anything", None))
elif what == "member":
    print(call("org.freedesktop.ScreenSaver", "Frobnicate", None))
elif what == "noreply":
    m = Gio.DBusMessage.new_method_call("org.freedesktop.ScreenSaver", "/org/freedesktop/ScreenSaver", "org.freedesktop.DBus.Properties", "GetAll")
    m.set_body(GLib.Variant("(s)", ("org.freedesktop.ScreenSaver",)))
    m.set_flags(Gio.DBusMessageFlags.NO_REPLY_EXPECTED)
    got = []
    c.add_filter(lambda conn, msg, inc: got.append(msg) or msg if inc and msg.get_message_type() in (Gio.DBusMessageType.METHOD_RETURN, Gio.DBusMessageType.ERROR) else msg)
    c.send_message(m, Gio.DBusSendMessageFlags.NONE)
    loop = GLib.MainLoop(); GLib.timeout_add(1000, loop.quit); loop.run()
    print("no reply" if not got else "unexpected reply")
PY
  }
  is() { [[ $(probe "$1") == "$2" ]]; }
  check "GetAll gives an empty dictionary" is getall "reply ({},)"
  check "Get gives UnknownProperty" is get "error org.freedesktop.DBus.Error.UnknownProperty"
  check "an unknown interface gives UnknownInterface" is iface "error org.freedesktop.DBus.Error.UnknownInterface"
  check "an unknown member gives UnknownMethod" is member "error org.freedesktop.DBus.Error.UnknownMethod"
  check "a NoReplyExpected call gets no reply" is noreply "no reply"
  check "the bridge still answers after it" is getall "reply ({},)"
fi
exit "$fail"
