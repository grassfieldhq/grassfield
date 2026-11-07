#!/usr/bin/env bash
# The Settings Wi-Fi and Bluetooth pages over D-Bus (GF-049), on a PRIVATE bus with FAKE NetworkManager and BlueZ services: the
# real code of apps/settings/src/systembus.cpp over a real D-Bus connection, nothing of the machine's network, Bluetooth or audio
# is reachable (the probe and the fakes refuse to start on anything but a private test bus).
#
#   1  the guard: the probe and the fakes refuse the real system bus and a missing GF_TEST_BUS (exit 2, before any connection)
#   2  wifi-state: radio, device, access points (the two "Home" ones, active flag, security flags), the saved Wi-Fi profile only
#   3  bt-state: adapter, powered, the paired devices (alias before name), not the unpaired one
#   4  Wi-Fi actions: radio, connect to a saved network, join an open one, a secured one is refused, disconnect, scan: each ends
#      in exactly the call the fake logged, with the arguments; the state follows
#   5  Bluetooth actions: power, connect, disconnect, likewise
#   6  failure feedback: a service's error becomes the short reason the page shows (permission, the service's own message)
#   7  dev guard: with the dev flag the state is read and every action is refused before it reaches the bus (the fake's log has
#      no new call)
#   8  a service that is not there: the reason says so
#   9  the window closes while a service is slow
#  10  General (ADR-0030): hostname1, timedate1, timesync1, locale1 read; the name, NTP, the zone and the time set with
#      interactive = true (the service asks polkit); a polkit refusal's reason; a bad zone refused before the bus; the user's own
#      services (the session bus) listed and switched, a shipped one refused; the dev guard sends none of these changes
#  11  the network panes (ADR-0030, NetworkManager): net-state (wlan0's addresses, router, name servers, band, link rate; the VPN
#      and WireGuard profiles with their state); a join with a password (key-mgmt wpa-psk, the password, the access point) kept
#      when it comes up, its new profile deleted when it goes down; Forget This Network deletes that profile and nothing else;
#      a VPN switched off and on; the dev guard sends none of these
#  13  Battery (UPower): the laptop battery, not the mouse's; the display device's level; the capacity, cycles, charge limit and
#      the charge history; EnableChargeThreshold, which then reads enabled; no battery service: the reason; the dev guard
#  12  Bluetooth discovery and pairing: the adapter's name, the nearby device (an RSSI) and a paired one's battery; discovery on and
#      off; Pair, Trusted and Connect on the nearby device, which is then paired; Forget removes a device; the dev guard
#  14  Printers (ADR-0030, cups-pk-helper): Add makes an "everywhere" queue and switches it on and to accepting jobs, Remove
#      deletes it; CUPS's message and a polkit refusal are the reason; the switches refused after an add leave the queue, and
#      Resume makes the two calls; bad values and the dev guard send nothing
#  15  Privacy & Security (the portal permission store, session bus): each category's applications (a malformed id dropped,
#      "ask" not allowed, no entry is none), the saved screen-sharing selection; a switch is SetPermission with the value the
#      portal reads (location [accuracy, timestamp], yes/no), Remove is Delete and an entry already gone is fine; bad values,
#      the dev guard and the store's own error; the Backend's caller never starts the desktop portal (a service the bus can
#      start, the control, is started)
#
# Needs a private dbus-daemon (a unix socket in the test's own directory; loopback TCP with anonymous auth where sockets cannot be
# created, as in a sandbox), g++ with the Qt 6 headers, python3 + PyGObject. SKIPs (exit 0) without them. Exit: 0 PASS, 1 FAIL,
# 2 environment error.
set -uo pipefail

root=$(git -C "$(dirname "$0")" rev-parse --show-toplevel)
fail=0
say() { printf '%s\n' "$*"; }
check() { # <description> <command...>
  local what=$1
  shift
  if "$@"; then say "  PASS $what"; else say "  FAIL $what"; fail=1; fi
}
die() { say "ENVIRONMENT: $*"; exit 2; }
wait_until() { # <seconds> <command...>
  local limit=$(($1 * 10)) i
  shift
  for ((i = 0; i < limit; i++)); do
    "$@" && return 0
    sleep 0.1
  done
  return 1
}

for tool in dbus-daemon python3 g++; do
  command -v "$tool" >/dev/null || { say "SKIP: settings_dbus needs $tool"; exit 0; }
done
[[ -f /usr/include/qt6/QtDBus/QDBusConnection ]] || { say "SKIP: settings_dbus needs the Qt 6 D-Bus headers"; exit 0; }
python3 -I -c 'import gi; gi.require_version("Gio", "2.0")' 2>/dev/null || { say "SKIP: settings_dbus needs PyGObject (gi, Gio)"; exit 0; }

work=$(mktemp -d "${TMPDIR:-/tmp}/gf-settings-dbus.XXXXXX") || die "no temp dir"
chmod 700 "$work"
bus_pid="" nm_pid="" bz_pid="" gen_pid="" up_pid="" cp_pid="" ps_pid=""
stop_all() {
  local p
  for p in "$nm_pid" "$bz_pid" "$gen_pid" "$up_pid" "$cp_pid" "$ps_pid" "$bus_pid"; do
    [[ -n $p ]] && kill "$p" 2>/dev/null
  done
  wait 2>/dev/null
  rm -rf "$work"
}
trap stop_all EXIT
# The scratch path goes into the bus configuration (XML) and a service file's Exec line: nothing there that needs quoting.
case $work in *[[:space:]\&\<\>\"\'\\]*) die "the scratch directory '$work' needs quoting (TMPDIR)" ;; esac

src=$root/apps/settings/src
# qtbuscaller.h's signal queue (signalqueue.h, ADR-0045 fprintd's enrolment) is a QObject: moc first.
moc=/usr/lib/qt6/moc
[[ -x $moc ]] || moc=$(command -v moc-qt6 || command -v moc || true)
[[ -n $moc ]] || die "moc not found"
"$moc" "$src/signalqueue.h" -o "$work/moc_signalqueue.cpp" 2>"$work/build.log" || { cat "$work/build.log"; die "moc failed on signalqueue.h"; }
g++ -std=c++17 -O1 -fPIC -Wno-sfinae-incomplete -I"$src" -I"$root/apps" -I/usr/include/qt6 -I/usr/include/qt6/QtCore -I/usr/include/qt6/QtDBus \
  "$root/tests/integration/settings_dbus/probe.cpp" "$src/systembus.cpp" "$src/systemguard.cpp" "$src/busjobs.cpp" "$work/moc_signalqueue.cpp" -pthread -lQt6Core -lQt6DBus -o "$work/probe" 2>"$work/build.log" ||
  { cat "$work/build.log"; die "the probe did not build"; }

# The private bus: a unix socket in the test's own directory; else loopback TCP with anonymous authentication (a sandbox that
# forbids unix sockets): a bus that lives for this test and serves only the fakes below. Its own configuration, never the
# system's session.conf: the only services it can start are the test's own ($work/services), and it runs with a clean
# environment, so no service of the machine (the real permission store or desktop portal) is ever started with the caller's
# home or runtime directory (review of 06da80f, MEDIUM-2).
mkdir -p "$work/services"
bus_conf() { # <listen address> <auth mechanism>: the bus configuration, on stdout
  cat <<EOF
<!DOCTYPE busconfig PUBLIC "-//freedesktop//DTD D-Bus Bus Configuration 1.0//EN" "http://www.freedesktop.org/standards/dbus/1.0/busconfig.dtd">
<busconfig>
  <type>session</type>
  <listen>$1</listen>
  <auth>$2</auth>
  $([[ $2 == ANONYMOUS ]] && echo '<allow_anonymous/>')
  <servicedir>$work/services</servicedir>
  <policy context="default">
    <allow send_destination="*" eavesdrop="true"/>
    <allow eavesdrop="true"/>
    <allow own="*"/>
  </policy>
</busconfig>
EOF
}
start_bus() {
  bus_conf "unix:path=$work/bus.sock" EXTERNAL >"$work/bus.conf"
  setsid env -i PATH="$PATH" HOME="$work" XDG_RUNTIME_DIR="$work" dbus-daemon --config-file="$work/bus.conf" --nofork --print-address=1 >"$work/bus.address" 2>"$work/bus.log" </dev/null &
  bus_pid=$!
  if wait_until 3 test -s "$work/bus.address"; then
    bus=$(head -n 1 "$work/bus.address")
    return 0
  fi
  kill "$bus_pid" 2>/dev/null
  wait "$bus_pid" 2>/dev/null
  bus_conf "tcp:host=127.0.0.1,port=0" ANONYMOUS >"$work/tcp.conf"
  : >"$work/bus.address"
  setsid env -i PATH="$PATH" HOME="$work" XDG_RUNTIME_DIR="$work" dbus-daemon --config-file="$work/tcp.conf" --nofork --print-address=1 >"$work/bus.address" 2>"$work/bus.log" </dev/null &
  bus_pid=$!
  wait_until 5 test -s "$work/bus.address" || return 1
  bus=$(head -n 1 "$work/bus.address")
}
start_bus || die "no private bus ($work/bus.log)"
case $bus in
  unix:path=$work/bus.sock* | tcp:host=127.0.0.1,*) ;;
  *) die "unexpected bus address '$bus'" ;;
esac
say "private bus ${bus%%,guid*} (dbus-daemon pid $bus_pid)"

# The session bus (the user's own services) is the same private bus. LC_ALL=C.UTF-8: under a plain C locale Qt prints a warning
# on stderr, which the probe's output would carry into the comparisons.
penv=(env -i LC_ALL=C.UTF-8 PATH="$PATH" HOME="$work" XDG_RUNTIME_DIR="$work" DBUS_SYSTEM_BUS_ADDRESS="$bus" DBUS_SESSION_BUS_ADDRESS="$bus" GF_TEST_BUS=1 GF_TEST_BUS_DIR="$work")
# GF_TEST_PRELOAD (optional): a library preloaded into the probe only. In a sandbox that has no interface but lo, libdbus cannot
# resolve its loopback TCP address (it asks getaddrinfo for AI_ADDRCONFIG), so such a run preloads a getaddrinfo that drops the flag.
probe() { timeout 30 "${penv[@]}" ${GF_TEST_PRELOAD:+LD_PRELOAD=$GF_TEST_PRELOAD} "$work/probe" "$@" 2>&1; }

start_service() { # nm|bluez|general|upower|cupspk|permstore [--fail ...]: sets nm_pid / bz_pid / gen_pid / up_pid / cp_pid / ps_pid
  local which=$1
  shift
  rm -f "$work/$which.ready"
  : >"$work/$which.log"
  setsid "${penv[@]}" python3 -I "$root/tests/fixtures/fake-system-service.py" "$which" --log "$work/$which.log" --ready "$work/$which.ready" "$@" >"$work/$which.err" 2>&1 </dev/null &
  case $which in nm) nm_pid=$! ;; bluez) bz_pid=$! ;; upower) up_pid=$! ;; cupspk) cp_pid=$! ;; permstore) ps_pid=$! ;; *) gen_pid=$! ;; esac
  wait_until 10 test -e "$work/$which.ready" || { cat "$work/$which.err"; die "the fake $which did not start"; }
}
stop_service() { # nm|bluez|general|upower|cupspk|permstore
  local pid
  case $1 in nm) pid=$nm_pid nm_pid="" ;; bluez) pid=$bz_pid bz_pid="" ;; upower) pid=$up_pid up_pid="" ;; cupspk) pid=$cp_pid cp_pid="" ;; permstore) pid=$ps_pid ps_pid="" ;; *) pid=$gen_pid gen_pid="" ;; esac
  [[ -n $pid ]] && { kill "$pid" 2>/dev/null; wait "$pid" 2>/dev/null; }
  sleep 0.3
}
# py <json> <python expression over `j`>: true when it holds
py() { python3 -I -c 'import json, sys; j = json.loads(sys.argv[1]); sys.exit(0 if eval(sys.argv[2]) else 1)' "$1" "$2"; }
# logged <nm|bluez> <member> <path-substring> <args-substring>: the fake logged such a call
logged() {
  python3 -I -c '
import json, sys
log, member, path, args = sys.argv[1:5]
for line in open(log):
    e = json.loads(line)
    if e["member"] == member and path in e["path"] and args in e["args"]:
        sys.exit(0)
sys.exit(1)' "$work/$1.log" "$2" "$3" "$4"
}
calls() { wc -l <"$work/$1.log" | tr -d ' '; }

# Preflight: libdbus must be able to reach this bus at all (an environment that forbids unix sockets and has no loopback address
# for libdbus to resolve cannot run this test: SKIP, it says nothing about the code).
pre=$(probe wifi-state)
case $pre in
  *"not connected"*) say "SKIP: settings_dbus: this environment gives libdbus no way to a private bus (${pre%%$'\n'*})"; exit 0 ;;
esac

start_service nm
start_service bluez

say ""
say "[1] the guard"
# The refusal parses the address: only unix:path=<socket under the scratch directory> or loopback tcp pass (every entry).
refused() { # ADDRESS...: the probe and the fake service both exit non-zero on it, whatever spelling it has
  local addr=$1 rc
  env -i PATH="$PATH" HOME="$work" GF_TEST_BUS=1 GF_TEST_BUS_DIR="$work" DBUS_SYSTEM_BUS_ADDRESS="$addr" timeout 10 "$work/probe" wifi-state >/dev/null 2>&1
  rc=$?
  [[ $rc -eq 2 ]] || return 1
  rm -f "$work/x.ready"
  env -i PATH="$PATH" HOME="$work" GF_TEST_BUS=1 GF_TEST_BUS_DIR="$work" DBUS_SYSTEM_BUS_ADDRESS="$addr" timeout 10 python3 -I "$root/tests/fixtures/fake-system-service.py" nm --log "$work/x.log" --ready "$work/x.ready" >/dev/null 2>&1
  [[ $? -ne 0 && ! -e "$work/x.ready" ]]
}
out=$(env -i PATH="$PATH" HOME="$work" GF_TEST_BUS=1 GF_TEST_BUS_DIR="$work" DBUS_SYSTEM_BUS_ADDRESS=unix:path=/run/dbus/system_bus_socket timeout 10 "$work/probe" wifi-state 2>&1)
rc=$?
check "the probe refuses the real system bus (exit 2: $out)" test "$rc" -eq 2
check "both refuse unix:path=/var/run/dbus/system_bus_socket" refused unix:path=/var/run/dbus/system_bus_socket
check "both refuse the same socket percent-escaped (unix:path=%2Frun%2Fdbus%2Fsystem_bus_socket)" refused 'unix:path=%2Frun%2Fdbus%2Fsystem_bus_socket'
check "both refuse a path that only starts like the scratch directory ($work/../x)" refused "unix:path=$work/../x.sock"
check "both refuse a socket next to the scratch directory (${work}x/bus)" refused "unix:path=${work}x/bus.sock"
check "both refuse an abstract socket, runtime=, systemd: and an unknown transport" bash -c '
  for a in "unix:abstract=/tmp/x" "unix:runtime=yes" "systemd:" "launchd:env=X" "nonce-tcp:host=127.0.0.1,port=1" "tcp:host=192.0.2.1,port=1" "tcp:port=1"; do
    env -i PATH="$PATH" GF_TEST_BUS=1 GF_TEST_BUS_DIR="$1" DBUS_SYSTEM_BUS_ADDRESS="$a" timeout 10 "$1/probe" wifi-state >/dev/null 2>&1
    [[ $? -eq 2 ]] || { echo "the probe did not refuse: $a"; exit 1; }
    rm -f "$1/x.ready"
    env -i PATH="$PATH" GF_TEST_BUS=1 GF_TEST_BUS_DIR="$1" DBUS_SYSTEM_BUS_ADDRESS="$a" timeout 10 python3 -I "$2/tests/fixtures/fake-system-service.py" nm --log "$1/x.log" --ready "$1/x.ready" >/dev/null 2>&1
    { [[ $? -ne 0 ]] && [[ ! -e "$1/x.ready" ]]; } || { echo "the fake service did not refuse: $a"; exit 1; }
  done' _ "$work" "$root"
check "both refuse a list that hides the real bus after a private entry" refused "unix:path=$work/bus.sock;unix:path=/run/dbus/system_bus_socket"
env -i PATH="$PATH" HOME="$work" GF_TEST_BUS_DIR="$work" DBUS_SYSTEM_BUS_ADDRESS="$bus" timeout 10 "$work/probe" wifi-state >/dev/null 2>&1
check "the probe refuses a run without GF_TEST_BUS=1" test "$?" -eq 2
env -i PATH="$PATH" HOME="$work" GF_TEST_BUS=1 DBUS_SYSTEM_BUS_ADDRESS="$bus" timeout 10 "$work/probe" wifi-state >/dev/null 2>&1
check "the probe refuses a run without GF_TEST_BUS_DIR" test "$?" -eq 2
env -i PATH="$PATH" HOME="$work" GF_TEST_BUS=1 GF_TEST_BUS_DIR="$work" timeout 10 "$work/probe" wifi-state >/dev/null 2>&1
check "the probe refuses a run with no bus address" test "$?" -eq 2

say ""
say "[2] Wi-Fi state"
st=$(probe wifi-state)
check "the state is JSON of a Wi-Fi radio that is on, with the device wlan0 connected" py "$st" 'j["radio"] is True and j["device"] == {"name": "wlan0", "connected": True}'
check "three access points: Home (active, strong), Home (weak), Cafe (open)" py "$st" 'len(j["aps"]) == 3 and [a["hex"] for a in j["aps"]].count("486F6D65") == 2 and sum(a["active"] for a in j["aps"]) == 1'
check "the open network has no security flags, the others carry RSN flags" py "$st" '[a["rsn"] for a in j["aps"] if a["hex"] == "43616665"] == [0] and all(a["rsn"] == 0x188 for a in j["aps"] if a["hex"] == "486F6D65")'
check "only the Wi-Fi profile is listed (the Ethernet one is not), with its SSID" py "$st" 'j["profiles"] == [{"uuid": "0f1e2d3c-4b5a-6978-8796-a5b4c3d2e1f0", "hex": "486F6D65"}]'
reads=$(calls nm)
check "reading made only read calls (no Set, no Activate, no Disconnect, no scan)" bash -c '! grep -qE "\"member\": \"(Set|ActivateConnection|AddAndActivateConnection|Disconnect|RequestScan)\"" "$1"' _ "$work/nm.log"
check "the fake saw the 7 method reads (GetDevices, GetAllAccessPoints, ListConnections, 4 x GetSettings; property reads are served by GDBus itself): $reads" test "$reads" -eq 7

say ""
say "[3] Bluetooth state"
bt=$(probe bt-state)
check "an adapter that is present and powered" py "$bt" 'j["present"] is True and j["powered"] is True'
check "the two paired devices, the alias before the name, connected as the fake says" py "$bt" 'sorted((d["mac"], d["name"], d["connected"]) for d in j["devices"]) == [("11:22:33:44:55:66", "Mouse", False), ("AA:BB:CC:DD:EE:FF", "Headphones", True)]'
check "the device that is only seen, not paired, is not listed" py "$bt" 'all(d["mac"] != "66:66:66:66:66:66" for d in j["devices"])'

say ""
say "[4] Wi-Fi actions"
out=$(probe act '{"op":"wifi.radio","on":false}')
check "radio off: ok" test "$out" = ok
check "... the fake got Set WirelessEnabled false on the NetworkManager object" logged nm Set /org/freedesktop/NetworkManager "WirelessEnabled false"
check "... and the state now says radio off with no access points listed" py "$(probe wifi-state)" 'j["radio"] is False and j["aps"] == []'
out=$(probe act '{"op":"wifi.radio","on":true}')
check "radio on: ok, and the state follows" py "$(probe wifi-state)" 'j["radio"] is True and len(j["aps"]) == 3'
out=$(probe act '{"op":"wifi.connectKnown","uuid":"0F1E2D3C-4B5A-6978-8796-A5B4C3D2E1F0"}')
check "connect to the saved network: ok" test "$out" = ok
check "... ActivateConnection(profile 1, device wlan0, \"/\")" logged nm ActivateConnection /org/freedesktop/NetworkManager "'/org/freedesktop/NetworkManager/Settings/1', objectpath '/org/freedesktop/NetworkManager/Devices/2', objectpath '/'"
before=$(calls nm)
out=$(probe act '{"op":"wifi.connectOpen","hex":"486F6D65"}')
check "a secured network is not joined from here: the reason says so" test "$out" = "failed: that network needs a password"
check "... and nothing was sent" test "$(calls nm)" -gt "$before" -a "$(grep -c AddAndActivateConnection "$work/nm.log")" -eq 0
out=$(probe act '{"op":"wifi.connectOpen","hex":"43616665"}')
check "join the open network Cafe: ok" test "$out" = ok
check "... AddAndActivateConnection with the access point Cafe, a Wi-Fi profile named Cafe and no security section" bash -c 'grep AddAndActivateConnection "$1" | grep -q "AccessPoint/3" && grep AddAndActivateConnection "$1" | grep -q "802-11-wireless" && ! grep AddAndActivateConnection "$1" | grep -q "security"' _ "$work/nm.log"
out=$(probe act '{"op":"wifi.disconnect"}')
check "disconnect: ok, Disconnect on wlan0, the state says not connected" bash -c '[[ $1 == ok ]]' _ "$out"
check "... Disconnect reached the Wi-Fi device" logged nm Disconnect /Devices/2 ""
check "... the state says not connected" py "$(probe wifi-state)" 'j["device"]["connected"] is False and not any(a["active"] for a in j["aps"])'
out=$(probe act '{"op":"wifi.scan"}')
check "scan: ok, RequestScan on wlan0" bash -c '[[ $1 == ok ]]' _ "$out"
check "... RequestScan reached the Wi-Fi device" logged nm RequestScan /Devices/2 ""
before=$(calls nm)
out=$(probe act '{"op":"wifi.connectKnown","uuid":"not-a-uuid"}')
check "a malformed action is refused before the bus (invalid request, no call)" bash -c '[[ $1 == "failed: invalid request" && $(wc -l <"$2") -eq $3 ]]' _ "$out" "$work/nm.log" "$before"

say ""
say "[5] Bluetooth actions"
out=$(probe act '{"op":"bt.power","on":false}')
check "power off: ok, Set Powered false on the adapter, the state follows" bash -c '[[ $1 == ok ]]' _ "$out"
check "... Set Powered false on /org/bluez/hci0" logged bluez Set /org/bluez/hci0 "Powered false"
check "... the state says not powered" py "$(probe bt-state)" 'j["powered"] is False'
probe act '{"op":"bt.power","on":true}' >/dev/null
out=$(probe act '{"op":"bt.connect","mac":"11:22:33:44:55:66","connect":true}')
check "connect the Mouse: ok, Connect on its object, the state follows" bash -c '[[ $1 == ok ]]' _ "$out"
check "... Connect reached dev_11_22_33_44_55_66" logged bluez Connect /org/bluez/hci0/dev_11_22_33_44_55_66 ""
check "... the Mouse is connected now" py "$(probe bt-state)" '[d["connected"] for d in j["devices"] if d["mac"] == "11:22:33:44:55:66"] == [True]'
out=$(probe act '{"op":"bt.connect","mac":"aa:bb:cc:dd:ee:ff","connect":false}')
check "disconnect the Headphones (lower-case address): ok, Disconnect on their object" bash -c '[[ $1 == ok ]]' _ "$out"
check "... Disconnect reached dev_AA_BB_CC_DD_EE_FF" logged bluez Disconnect /org/bluez/hci0/dev_AA_BB_CC_DD_EE_FF ""
out=$(probe act '{"op":"bt.connect","mac":"01:02:03:04:05:06","connect":true}')
check "a device that is not paired: the reason says so" test "$out" = "failed: that device is no longer paired"
out=$(probe act '{"op":"bt.connect","mac":"66:66:66:66:66:66","connect":true}')
check "a device that is seen but not paired is not connected: the reason says so" test "$out" = "failed: that device is not paired yet"
check "... and no Connect reached it" bash -c '! grep -q "dev_66_66_66_66_66_66.*\"member\": \"Connect\"" "$1"' _ "$work/bluez.log"

say ""
say "[6] failure feedback"
stop_service nm
start_service nm --fail 'ActivateConnection=org.freedesktop.NetworkManager.PermissionDenied|Not authorized to control networking'
out=$(probe act '{"op":"wifi.connectKnown","uuid":"0f1e2d3c-4b5a-6978-8796-a5b4c3d2e1f0"}')
check "a refused activation gives the page a reason ($out)" test "$out" = "failed: not allowed: the system refused the request"
stop_service nm
start_service nm --fail 'Disconnect=org.freedesktop.NetworkManager.Device.NotActive|The device is not active'
out=$(probe act '{"op":"wifi.disconnect"}')
check "the service's own message is the reason ($out)" test "$out" = "failed: The device is not active"
stop_service bluez
start_service bluez --fail 'Connect=org.bluez.Error.Failed|Software caused connection abort'
out=$(probe act '{"op":"bt.connect","mac":"11:22:33:44:55:66","connect":true}')
check "a failed Bluetooth connect gives BlueZ's message ($out)" test "$out" = "failed: Software caused connection abort"

say ""
say "[7] dev guard"
stop_service nm
stop_service bluez
start_service nm
start_service bluez
before_nm=$(calls nm)
before_bz=$(calls bluez)
out=$(probe --dev wifi-state)
check "a dev session still reads the Wi-Fi state" py "$out" 'j["radio"] is True and len(j["aps"]) == 3'
check "a dev session still reads the Bluetooth state" py "$(probe --dev bt-state)" 'len(j["devices"]) == 2'
fine=1
for op in '{"op":"wifi.radio","on":false}' '{"op":"wifi.connectKnown","uuid":"0f1e2d3c-4b5a-6978-8796-a5b4c3d2e1f0"}' '{"op":"wifi.connectOpen","hex":"43616665"}' '{"op":"wifi.disconnect"}' '{"op":"wifi.scan"}' \
  '{"op":"bt.power","on":false}' '{"op":"bt.connect","mac":"11:22:33:44:55:66","connect":true}'; do
  out=$(probe --dev act "$op")
  case $out in "failed: dev guard"*) ;; *) fine=0; say "    not refused: $op -> $out" ;; esac
done
check "in a dev session every action is refused by the guard" test "$fine" -eq 1
check "... and none of them reached either bus service: only reads in the logs" bash -c '! grep -qE "\"member\": \"(Set|ActivateConnection|AddAndActivateConnection|Disconnect|RequestScan|Connect)\"" "$1" "$2"' _ "$work/nm.log" "$work/bluez.log"

say ""
say "[8] a service that is not there"
stop_service nm
stop_service bluez
out=$(probe wifi-state)
check "no NetworkManager: the reason says the service is not running ($out)" test "$out" = "failed: the service is not running"
out=$(probe bt-state)
check "no BlueZ: likewise ($out)" test "$out" = "failed: the service is not running"
out=$(probe act '{"op":"wifi.radio","on":false}')
check "an action on a service that is not there fails with that reason ($out)" test "$out" = "failed: the service is not running"

say ""
say "[9] the window closes while a service is slow"
start_service bluez --slow Connect=5
start=$SECONDS
out=$(probe close-midjob)
rc=$?
check "no callback after the close, the destructor does not wait for the service, the stuck job is abandoned ($out)" test "$rc" -eq 0
check "... and the process is gone long before the service answers (took $((SECONDS - start)) s of its 5 s)" test "$((SECONDS - start))" -lt 4
stop_service bluez

say ""
say "[10] General (ADR-0030)"
start_service general
check "the probe refuses a session bus that is not the private one" bash -c '
  env -i PATH="$PATH" GF_TEST_BUS=1 GF_TEST_BUS_DIR="$1" DBUS_SYSTEM_BUS_ADDRESS="$2" DBUS_SESSION_BUS_ADDRESS=unix:path=/run/user/1000/bus timeout 10 "$1/probe" units-state >/dev/null 2>&1
  [[ $? -eq 2 ]]' _ "$work" "$bus"
check "hostname1: the reference laptop, its pretty and static names" py "$(probe host-state)" 'j == {"pretty": "Grassfield Reference", "static": "grassfield-reference", "hostname": "grassfield-reference", "chassis": "laptop", "vendor": "Grassfield", "model": "Reference Laptop 14"}'
st=$(probe time-state)
check "timedate1 + timesync1: the zone, NTP, the time and the servers" py "$st" 'j["zone"] == "Europe/Paris" and j["ntp"] and j["canNtp"] and j["usec"] == "1792832460000000" and j["server"] == "2.arch.pool.ntp.org" and len(j["servers"]) == 3'
check "ListTimezones: the zones, a malformed one dropped" py "$(probe time-zones)" 'j["zones"] == ["Europe/Paris", "Europe/Zurich", "America/New_York", "UTC"]'
check "locale1: the system locale" py "$(probe locale-state)" 'j["locale"] == ["LANG=en_US.UTF-8"]'
out=$(probe act '{"op":"host.setName","name":"Studio Desk"}')
check "rename: ok" test "$out" = ok
check "... SetPrettyHostname('Studio Desk', interactive true)" logged general SetPrettyHostname /org/freedesktop/hostname1 "'Studio Desk', true"
check "... then SetStaticHostname of the derived name, interactive true" logged general SetStaticHostname /org/freedesktop/hostname1 "'studio-desk', true"
check "... and hostname1 now says so" py "$(probe host-state)" 'j["pretty"] == "Studio Desk" and j["static"] == "studio-desk"'
out=$(probe act '{"op":"time.ntp","on":false}')
check "automatic time off: ok, SetNTP(false, interactive true)" bash -c '[[ $1 == ok ]]' _ "$out"
check "... SetNTP(false, true)" logged general SetNTP /org/freedesktop/timedate1 "false, true"
out=$(probe act '{"op":"time.zone","zone":"Europe/Zurich"}')
check "time zone: ok, SetTimezone('Europe/Zurich', interactive true)" logged general SetTimezone /org/freedesktop/timedate1 "'Europe/Zurich', true"
out=$(probe act '{"op":"time.set","usec":"1800000000000000"}')
check "set the time: ok, SetTime(usec, absolute, interactive true)" logged general SetTime /org/freedesktop/timedate1 "1800000000000000, false, true"
check "... and timedate1 now reads the new zone, NTP off and the new time" py "$(probe time-state)" 'j["zone"] == "Europe/Zurich" and not j["ntp"] and j["usec"] == "1800000000000000"'
before=$(calls general)
out=$(probe act '{"op":"time.zone","zone":"../../etc/passwd"}')
check "a bad zone is refused before the bus (invalid request, no call)" bash -c '[[ $1 == "failed: invalid request" && $(wc -l <"$2") -eq $3 ]]' _ "$out" "$work/general.log" "$before"
out=$(probe act '{"op":"time.set","usec":"1"}')
check "a time before 2000 is refused before the bus" test "$out" = "failed: invalid request"
check "units: the user's own services only (not the one a package ships)" py "$(probe units-state)" 'sorted((u["unit"], u["state"]) for u in j["units"]) == [("backup.service", "disabled"), ("sync.service", "enabled")]'
out=$(probe act '{"op":"user.enable","unit":"backup.service","on":true}')
check "switch the user's backup service on: ok" test "$out" = ok
check "... EnableUnitFiles(['backup.service'], runtime false, force false), then Reload" bash -c 'grep EnableUnitFiles "$1" | grep -q "\[.backup.service.\], false, false" && grep -q "\"member\": \"Reload\"" "$1"' _ "$work/general.log"
check "... and it reads enabled" py "$(probe units-state)" '[u["state"] for u in j["units"] if u["unit"] == "backup.service"] == ["enabled"]'
out=$(probe act '{"op":"user.enable","unit":"shipped.service","on":false}')
check "a service a package ships is refused ($out)" test "$out" = "failed: that item is not one of your own"
check "... and DisableUnitFiles never reached the manager" bash -c '! grep -q DisableUnitFiles "$1"' _ "$work/general.log"
stop_service general
start_service general --fail 'SetTimezone=org.freedesktop.PolicyKit1.Error.NotAuthorized|Interactive authentication required.'
out=$(probe act '{"op":"time.zone","zone":"Europe/Zurich"}')
check "a polkit refusal (a cancelled dialog) becomes the page's reason ($out)" test "$out" = "failed: not allowed: the system refused the request"
stop_service general
start_service general
fine=1
for op in '{"op":"host.setName","name":"Dev"}' '{"op":"time.ntp","on":false}' '{"op":"time.zone","zone":"UTC"}' '{"op":"time.set","usec":"1800000000000000"}' \
  '{"op":"user.enable","unit":"sync.service","on":false}'; do
  out=$(probe --dev act "$op")
  case $out in "failed: dev guard"*) ;; *) fine=0; say "    not refused: $op -> $out" ;; esac
done
check "in a dev session every General change is refused by the guard" test "$fine" -eq 1
check "... a dev session still reads hostname1 and timedate1" py "$(probe --dev time-state)" 'j["zone"] == "Europe/Paris"'
check "... and no Set*, Enable or Disable call reached the services" bash -c '! grep -qE "\"member\": \"(Set[A-Za-z]*|EnableUnitFiles|DisableUnitFiles|Reload)\"" "$1"' _ "$work/general.log"
stop_service general

say ""
say "[11] network panes (net-state, password join, Forget, VPN)"
start_service nm
st=$(probe net-state)
check "net-state: wlan0 connected with its address, router, name servers, band and link rate" py "$st" '[(d["name"], d["state"], d["ip4"], d["router"], d["dns"], d["ip6"], d["frequency"], d["bitrate"], d["connection"]) for d in j["devices"] if d["type"] == "wifi"] == [("wlan0", "connected", ["192.168.20.34/24"], "192.168.20.1", ["192.168.20.1", "9.9.9.9"], ["fd00:20::34/64"], 5180, 866000, "Maison")]'
check "... eth0 without a cable is unavailable, its speed read from Device.Wired" py "$st" '[(d["state"], d["speed"]) for d in j["devices"] if d["type"] == "ethernet"] == [("unavailable", 1000)]'
check "... no systemd on this bus: no firewall, and the state is still read" py "$st" 'j["firewall"] == {"name": "", "active": False}'
check "... the VPN (connected) and the WireGuard profile (off), not the Wi-Fi or Ethernet ones" py "$st" 'sorted((v["name"], v["kind"], v["state"]) for v in j["vpns"]) == [("Home WireGuard", "wireguard", "disconnected"), ("Office VPN", "vpn", "connected")]'
out=$(probe act '{"op":"wifi.connectSecure","hex":"486F6D65","psk":"correct horse"}')
check "join Home with its password: ok ($out)" test "$out" = ok
check "... AddAndActivateConnection with key-mgmt wpa-psk, the password, on the stronger Home" bash -c 'grep AddAndActivateConnection "$1" | grep "wpa-psk" | grep "correct horse" | grep -q "AccessPoint/1"' _ "$work/nm.log"
check "... and its new profile is kept (no Delete)" bash -c '! grep -q "\"member\": \"Delete\"" "$1"' _ "$work/nm.log"
out=$(probe act '{"op":"wifi.connectSecure","hex":"486F6D65","psk":"wrong horse"}')
check "a wrong password: the join fails with a reason ($out)" test "$out" = "failed: the network could not be joined"
check "... and the profile it added is deleted" logged nm Delete /Settings/9 ""
out=$(probe act '{"op":"wifi.connectSecure","hex":"43616665","psk":"correct horse"}')
check "an open network takes no password ($out)" test "$out" = "failed: that network does not take a password"
out=$(probe act '{"op":"wifi.connectSecure","hex":"486F6D65","psk":"short"}')
check "a password NetworkManager would refuse never reaches it ($out)" test "$out" = "failed: invalid request"
out=$(probe act '{"op":"wifi.forget","uuid":"0f1e2d3c-4b5a-6978-8796-a5b4c3d2e1f0"}')
check "Forget This Network: ok ($out)" test "$out" = ok
check "... Delete reached Home's profile" logged nm Delete /Settings/1 ""
check "... and Home is no longer a saved network" py "$(probe wifi-state)" 'j["profiles"] == []'
out=$(probe act '{"op":"wifi.forget","uuid":"5b6c7d8e-9f00-4a1b-8c2d-3e4f5a6b7c8e"}')
check "a VPN's uuid is not a network to forget ($out)" test "$out" = "failed: that network is no longer saved"
check "... and its profile was not deleted" bash -c '! grep "\"member\": \"Delete\"" "$1" | grep -q Settings/3' _ "$work/nm.log"
out=$(probe act '{"op":"vpn.connect","uuid":"5b6c7d8e-9f00-4a1b-8c2d-3e4f5a6b7c8e","on":false}')
check "switch the VPN off: ok ($out)" test "$out" = ok
check "... DeactivateConnection of its active connection" logged nm DeactivateConnection /org/freedesktop/NetworkManager "ActiveConnection/3"
check "... and it reads off" py "$(probe net-state)" '[v["state"] for v in j["vpns"] if v["name"] == "Office VPN"] == ["disconnected"]'
out=$(probe act '{"op":"vpn.connect","uuid":"6c7d8e9f-0011-4b2c-9d3e-4f5a6b7c8d9f","on":true}')
check "switch the WireGuard profile on: ok ($out)" test "$out" = ok
check "... ActivateConnection(its profile, no device, no object)" logged nm ActivateConnection /org/freedesktop/NetworkManager "'/org/freedesktop/NetworkManager/Settings/4', objectpath '/', objectpath '/'"
# A fresh world: Home's profile is saved again, so a Forget gets as far as the guard.
stop_service nm
start_service nm
before=$(calls nm)
fine=1
for op in '{"op":"wifi.connectSecure","hex":"486F6D65","psk":"correct horse"}' '{"op":"wifi.forget","uuid":"0f1e2d3c-4b5a-6978-8796-a5b4c3d2e1f0"}' \
  '{"op":"vpn.connect","uuid":"5b6c7d8e-9f00-4a1b-8c2d-3e4f5a6b7c8e","on":true}'; do
  out=$(probe --dev act "$op")
  case $out in "failed: dev guard"*) ;; *) fine=0; say "    not refused: $op -> $out" ;; esac
done
check "in a dev session a join, a Forget and a VPN switch are refused by the guard" test "$fine" -eq 1
check "... a dev session still reads net-state" py "$(probe --dev net-state)" 'len(j["devices"]) == 2'
check "... and none of them reached NetworkManager" bash -c 'tail -n +$(($2 + 1)) "$1" | grep -qE "\"member\": \"(AddAndActivateConnection|Delete|ActivateConnection|DeactivateConnection)\"" && exit 1 || exit 0' _ "$work/nm.log" "$before"
stop_service nm

say ""
say "[12] Bluetooth discovery and pairing"
start_service bluez
bt=$(probe bt-state)
check "the adapter's name and the nearby keyboard (in range, not paired), not the device only seen earlier" py "$bt" 'j["alias"] == "gf-test" and [(n["mac"], n["name"], n["icon"], n["rssi"]) for n in j["nearby"]] == [("33:33:33:33:33:33", "Keyboard K3", "input-keyboard", -48)]'
check "... the Headphones' battery and icon" py "$bt" '[(d["battery"], d["icon"]) for d in j["devices"] if d["mac"] == "AA:BB:CC:DD:EE:FF"] == [(80, "audio-headphones")]'
out=$(probe act '{"op":"bt.discover","on":true}')
check "discovery on: ok ($out), StartDiscovery on the adapter, and the state says so" bash -c '[[ $1 == ok ]]' _ "$out"
check "... StartDiscovery reached /org/bluez/hci0" logged bluez StartDiscovery /org/bluez/hci0 ""
check "... discovering" py "$(probe bt-state)" 'j["discovering"] is True'
out=$(probe act '{"op":"bt.pair","mac":"33:33:33:33:33:33"}')
check "pair the keyboard: ok ($out)" test "$out" = ok
check "... Pair, then Set Trusted true, then Connect on its object" bash -c 'grep dev_33_33_33_33_33_33 "$1" | python3 -I -c "import json,sys; m=[json.loads(l)[\"member\"] for l in sys.stdin]; sys.exit(0 if m==[\"Pair\",\"Set\",\"Connect\"] else 1)" && grep dev_33 "$1" | grep -q "Trusted true"' _ "$work/bluez.log"
check "... the keyboard is paired and connected now" py "$(probe bt-state)" '[(d["connected"]) for d in j["devices"] if d["mac"] == "33:33:33:33:33:33"] == [True] and j["nearby"] == []'
out=$(probe act '{"op":"bt.forget","mac":"11:22:33:44:55:66"}')
check "forget the Mouse: ok ($out)" test "$out" = ok
check "... RemoveDevice(its object) on the adapter" logged bluez RemoveDevice /org/bluez/hci0 "dev_11_22_33_44_55_66"
check "... and it is gone" py "$(probe bt-state)" 'all(d["mac"] != "11:22:33:44:55:66" for d in j["devices"])'
out=$(probe act '{"op":"bt.discover","on":false}')
check "discovery off: ok ($out)" test "$out" = ok
before=$(calls bluez)
fine=1
for op in '{"op":"bt.discover","on":true}' '{"op":"bt.pair","mac":"33:33:33:33:33:33"}' '{"op":"bt.forget","mac":"AA:BB:CC:DD:EE:FF"}'; do
  out=$(probe --dev act "$op")
  case $out in "failed: dev guard"*) ;; *) fine=0; say "    not refused: $op -> $out" ;; esac
done
check "in a dev session discovery, pairing and Forget are refused by the guard" test "$fine" -eq 1
check "... and none of them reached BlueZ" bash -c 'tail -n +$(($2 + 1)) "$1" | grep -qE "\"member\": \"(StartDiscovery|Pair|RemoveDevice|Set|Connect)\"" && exit 1 || exit 0' _ "$work/bluez.log" "$before"
stop_service bluez

say ""
say "[13] Battery (UPower)"
out=$(probe power-state)
check "no UPower: the reason says the service is not running ($out)" test "$out" = "failed: the service is not running"
start_service upower
st=$(probe power-state)
check "the laptop battery, on battery, the display device's level and time" py "$st" 'j["present"] is True and j["onBattery"] is True and j["percent"] == 71.0 and j["state"] == 2 and j["timeToEmpty"] == 7300'
check "... its capacity, cycles and charge limit (supported, off, 80 %)" py "$st" '(j["capacity"], j["cycles"], j["limitSupported"], j["limitEnabled"], j["limitEnd"]) == (91.5, 212, True, False, 80)'
check "... its charge history, of the laptop battery only (not the mouse's)" py "$st" 'j["history24"] == [[1792800000, 80.0, 2], [1792803600, 75.5, 2]] and len(j["history10"]) == 2'
check "... GetHistory('charge', 86400, 96) reached the battery" logged upower GetHistory battery_BAT0 "'charge', uint32 86400, uint32 96"
check "... and never the mouse" bash -c '! grep GetHistory "$1" | grep -q mouse' _ "$work/upower.log"
out=$(probe act '{"op":"power.chargeLimit","on":true}')
check "limit charging: ok ($out)" test "$out" = ok
check "... EnableChargeThreshold(true) on the battery" logged upower EnableChargeThreshold battery_BAT0 "true"
check "... and it reads enabled" py "$(probe power-state)" 'j["limitEnabled"] is True'
before=$(calls upower)
out=$(probe --dev act '{"op":"power.chargeLimit","on":false}')
check "in a dev session the charge limit is refused by the guard ($out)" bash -c '[[ $1 == "failed: dev guard"* ]]' _ "$out"
check "... a dev session still reads the battery" py "$(probe --dev power-state)" 'j["present"] is True'
check "... and no EnableChargeThreshold reached UPower" bash -c 'tail -n +$(($2 + 1)) "$1" | grep -q EnableChargeThreshold && exit 1 || exit 0' _ "$work/upower.log" "$before"
stop_service upower

say ""
say "[14] Printers (cups-pk-helper)"
add='{"op":"printer.add","name":"GF_Studio","uri":"dnssd://GF%20Studio._ipp._tcp.local/?uuid=0f1e2d3c","info":"GF Studio"}'
out=$(probe act "$add")
check "no cups-pk-helper: the reason says the service is not running ($out)" test "$out" = "failed: the service is not running"
start_service cupspk
out=$(probe act "$add")
check "Add Printer: ok ($out)" test "$out" = ok
check "... PrinterAdd with the name, the URI, the model everywhere, the description and no location" logged cupspk PrinterAdd / "'GF_Studio', 'dnssd://GF%20Studio._ipp._tcp.local/?uuid=0f1e2d3c', 'everywhere', 'GF Studio', ''"
check "... then PrinterSetEnabled('GF_Studio', true)" logged cupspk PrinterSetEnabled / "'GF_Studio', true"
check "... and PrinterSetAcceptJobs('GF_Studio', true, '')" logged cupspk PrinterSetAcceptJobs / "'GF_Studio', true, ''"
members() { python3 -I -c 'import json, sys; print(",".join(json.loads(l)["member"] for l in open(sys.argv[1])))' "$work/$1.log"; }
check "... in that order, and nothing else" test "$(members cupspk)" = "PrinterAdd,PrinterSetEnabled,PrinterSetAcceptJobs"
out=$(probe act '{"op":"printer.delete","name":"GF_Studio"}')
check "Remove Printer: ok ($out)" test "$out" = ok
check "... PrinterDelete('GF_Studio')" logged cupspk PrinterDelete / "'GF_Studio'"
out=$(probe act '{"op":"printer.delete","name":"GF_Studio"}')
check "removing it again: CUPS's own message is the reason ($out)" test "$out" = "failed: client-error-not-found"
before=$(calls cupspk)
fine=1
for op in '{"op":"printer.add","name":"-x","uri":"ipp://192.0.2.7/ipp/print","info":"X"}' '{"op":"printer.add","name":"X","uri":"usb://Brother/HL","info":"X"}'   '{"op":"printer.add","name":"X","uri":"ipp://192.0.2.7/ipp/print","info":""}' '{"op":"printer.delete","name":"a b"}'; do
  out=$(probe act "$op")
  case $out in "failed: invalid request"*) ;; *) fine=0; say "    not refused: $op -> $out" ;; esac
done
check "a bad name, a URI cupsd would not make driverless, no description: refused before the bus" test "$fine" -eq 1
fine=1
for op in "$add" '{"op":"printer.delete","name":"GF_Office"}'; do
  out=$(probe --dev act "$op")
  case $out in "failed: dev guard"*) ;; *) fine=0; say "    not refused: $op -> $out" ;; esac
done
check "in a dev session Add and Remove are refused by the guard" test "$fine" -eq 1
check "... and none of these reached cups-pk-helper" test "$(calls cupspk)" -eq "$before"
stop_service cupspk
start_service cupspk --fail 'PrinterAdd=org.opensuse.CupsPkHelper.Mechanism.NotPrivileged|Not Authorized'
out=$(probe act "$add")
check "a polkit refusal: not allowed, and the queue is neither enabled nor opened ($out)" bash -c '[[ $1 == "failed: not allowed: the system refused the request" ]] && ! grep -q PrinterSetEnabled "$2"' _ "$out" "$work/cupspk.log"
stop_service cupspk
# The helper may ask again for the two switches (other polkit actions): refused there, the queue stays, stopped; Resume makes
# the same two calls.
start_service cupspk --fail 'PrinterSetEnabled=org.opensuse.CupsPkHelper.Mechanism.NotPrivileged|Not Authorized'
out=$(probe act "$add")
made=$(members cupspk)
check "the switches refused after an add: not allowed ($out), PrinterAdd made, PrinterSetAcceptJobs not tried ($made)" bash -c '[[ $1 == "failed: not allowed: the system refused the request" && $2 == PrinterAdd,PrinterSetEnabled ]]' _ "$out" "$made"
stop_service cupspk
start_service cupspk
out=$(probe act '{"op":"printer.resume","name":"GF_Office"}')
made=$(members cupspk)
check "Resume: ok ($out), PrinterSetEnabled then PrinterSetAcceptJobs on the queue, nothing else ($made)" bash -c '[[ $1 == ok && $2 == PrinterSetEnabled,PrinterSetAcceptJobs ]]' _ "$out" "$made"
check "... with the queue's name" logged cupspk PrinterSetAcceptJobs / "'GF_Office', true, ''"
out=$(probe --dev act '{"op":"printer.resume","name":"GF_Office"}')
made=$(members cupspk)
check "in a dev session Resume is refused by the guard ($out), nothing more reached the helper" bash -c '[[ $1 == "failed: dev guard"* && $2 == PrinterSetEnabled,PrinterSetAcceptJobs ]]' _ "$out" "$made"
stop_service cupspk

say ""
say "[15] Privacy & Security (the portal permission store)"
out=$(probe privacy-state)
check "no permission store: the reason says the service is not running ($out)" test "$out" = "failed: the service is not running"
# The desktop portal is never started by Settings (qtbuscaller.h; review of 06da80f, LOW-1): this bus can start a service (the
# control, a marker written by its activation), and the same call to the portal starts nothing. The service writes its marker
# and exits 1, which the bus answers at once (an exit 0 it answers only when the activation times out).
for name in org.grassfield.test.Activatable org.freedesktop.portal.Desktop; do
  printf "[D-BUS Service]\nName=%s\nExec=%s -c 'touch %s; exit 1'\n" "$name" "$(command -v sh)" "$work/started.$name" >"$work/services/$name.service"
done
out=$(probe autostart-get org.grassfield.test.Activatable)
check "the control: this bus starts a service it can activate ($out)" test -e "$work/started.org.grassfield.test.Activatable"
out=$(probe autostart-get org.freedesktop.portal.Desktop)
check "... the Backend's caller never starts the desktop portal ($out)" test ! -e "$work/started.org.freedesktop.portal.Desktop"
rm -f "$work/services/"*.service
start_service permstore
token=00000000-1111-2222-3333-444444444444
token2=_0000_fake_0000_0000_
st=$(probe privacy-state)
check "location: Maps allowed (EXACT), Weather not (NONE), the malformed id dropped" py "$st" 'j["location"] == [{"app": "org.example.Maps", "allowed": True}, {"app": "org.example.Weather", "allowed": False}]'
check "camera: Meet allowed, Booth's \"ask\" is not" py "$st" 'j["camera"] == [{"app": "org.example.Booth", "allowed": False}, {"app": "org.example.Meet", "allowed": True}]'
check "no background entry and no remote desktop table: none (NotFound is not an error)" py "$st" 'j["background"] == [] and j["remoteDesktop"] == []'
check "screen sharing: Meet's and Studio's saved selections (a current token beginning with _ too), and the one of a host app the portal could not name, under \"\"" py "$st" 'j["screencast"] == [{"app": "org.example.Meet", "token": "'"$token"'"}, {"app": "org.example.Studio", "token": "'"$token2"'"}, {"app": "", "token": "hostToken_0000"}]'
check "the portals: Background exported, RemoteDesktop not" py "$st" 'j["portals"] == {"background": True, "remoteDesktop": False}'
check "... read with Lookup and List only" bash -c '[[ -z $(grep -v "\"member\": \"\(Lookup\|List\)\"" "$1") ]]' _ "$work/permstore.log"
out=$(probe act '{"op":"privacy.allow","category":"camera","app":"org.example.Booth","on":true}')
check "allow Booth the camera: ok ($out)" test "$out" = ok
check "... SetPermission('devices', create, 'camera', Booth, ['yes'])" logged permstore SetPermission /org/freedesktop/impl/portal/PermissionStore "'devices', true, 'camera', 'org.example.Booth', ['yes']"
out=$(probe act '{"op":"privacy.allow","category":"location","app":"org.example.Maps","on":false}')
check "Maps's location off: ok ($out), SetPermission of ['NONE', '0'] (two elements, as the portal reads it)" logged permstore SetPermission / "'location', true, 'location', 'org.example.Maps', ['NONE', '0']"
out=$(probe act '{"op":"privacy.allow","category":"location","app":"org.example.Weather","on":true}')
check "Weather's location on: ['EXACT', '0']" logged permstore SetPermission / "'location', true, 'location', 'org.example.Weather', ['EXACT', '0']"
out=$(probe act '{"op":"privacy.allow","category":"background","app":"org.example.Meet","on":false}')
check "Meet in the background off: ok ($out), a new background entry with ['no']" logged permstore SetPermission / "'background', true, 'background', 'org.example.Meet', ['no']"
out=$(probe act '{"op":"privacy.forget","kind":"screencast","token":"'"$token"'"}')
check "remove the saved selection: ok ($out), Delete('screencast', token)" logged permstore Delete / "'screencast', '$token'"
out=$(probe act '{"op":"privacy.forget","kind":"screencast","token":"'"$token2"'"}')
check "remove the one with a current token: ok ($out), Delete('screencast', token)" logged permstore Delete / "'screencast', '$token2'"
out=$(probe act '{"op":"privacy.forget","kind":"screencast","token":"hostToken_0000"}')
check "remove the unnamed host app's: ok ($out), Delete('screencast', token)" logged permstore Delete / "'screencast', 'hostToken_0000'"
st=$(probe privacy-state)
check "... and the store now reads every change" py "$st" 'j["camera"][0] == {"app": "org.example.Booth", "allowed": True} and [a["allowed"] for a in j["location"]] == [False, True] and j["background"] == [{"app": "org.example.Meet", "allowed": False}] and j["screencast"] == []'
out=$(probe act '{"op":"privacy.forget","kind":"screencast","token":"'"$token"'"}')
check "removing it again (already gone): ok ($out)" test "$out" = ok
before=$(calls permstore)
fine=1
for op in '{"op":"privacy.allow","category":"microphone","app":"org.example.Meet","on":true}' '{"op":"privacy.allow","category":"camera","app":"../x","on":true}' \
  '{"op":"privacy.allow","category":"camera","app":"org.example.Meet","on":"yes"}' '{"op":"privacy.forget","kind":"screenshot","token":"abc"}' \
  '{"op":"privacy.forget","kind":"screencast","token":"a b"}'; do
  out=$(probe act "$op")
  case $out in "failed: invalid request"*) ;; *) fine=0; say "    not refused: $op -> $out" ;; esac
done
check "an unknown category or kind, a malformed id or token, a switch that is not a boolean: refused before the bus" test "$fine" -eq 1
check "... and none of these reached the store" test "$(calls permstore)" -eq "$before"
check "in a dev session the state is read, the portals with it" py "$(probe --dev privacy-state)" 'len(j["location"]) == 2 and j["portals"] == {"background": True, "remoteDesktop": False}'
before=$(grep -vc '"member": "\(Lookup\|List\)"' "$work/permstore.log")
fine=1
for op in '{"op":"privacy.allow","category":"camera","app":"org.example.Meet","on":false}' '{"op":"privacy.forget","kind":"screencast","token":"abc"}'; do
  out=$(probe --dev act "$op")
  case $out in "failed: dev guard"*) ;; *) fine=0; say "    not refused: $op -> $out" ;; esac
done
check "in a dev session a switch and Remove are refused by the guard" test "$fine" -eq 1
check "... and the store got no write" test "$(grep -vc '"member": "\(Lookup\|List\)"' "$work/permstore.log")" -eq "$before"
stop_service permstore
start_service permstore --fail 'SetPermission=org.freedesktop.portal.Error.Failed|Unable to write the permission database'
out=$(probe act '{"op":"privacy.allow","category":"camera","app":"org.example.Meet","on":false}')
check "the store's own error is the reason ($out)" test "$out" = "failed: Unable to write the permission database"
stop_service permstore

say ""
if ((fail)); then say "FAIL"; else say "PASS"; fi
exit "$fail"
