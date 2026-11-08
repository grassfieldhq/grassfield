#!/usr/bin/env bash
# Nested scenario DT-10 (GF-AUDIT-001 SEC-12 / GF-070), as amended on 2026-11-08 (ADR-0011 amendment, the Gatekeeper
# model): Grassfield Files never runs an app launcher, never runs a script by opening it, and runs a downloaded program only
# after the user's Open in its sheet. A sandbox folder holds t.desktop (Type=Application, executable), u.desktop (the same,
# not executable), Invoice.pdf.desktop, run.sh (executable) and Invoice (a native program carrying a browser's download mark,
# .dev/build/launch-fixtures/probe, which leaves "Invoice.launched" in its working folder, the isolated home); each
# launcher's Exec and the script would create
# a marker file. Pass 1 runs Files with GRASSFIELD_FILES_NO_LAUNCH=1: the three launchers are refused by the guard (log "open
# refused") before the test switch, the script and the program stop at the switch ("launch blocked", twice) before any editor
# or sheet. Pass 2 runs Files WITHOUT the switch on the launchers and the program: the launchers are refused, the program's
# sheet is asked ("open asked (program)") and answered with Return, which cancels ("open canceled (program)"); neither the
# marker nor "Invoice.launched" may appear. Items are opened with type-to-select + Ctrl+O (Return renames, as in the Finder).
#
# Safety as tests/apps/files_sandbox.sh: everything under .dev/files-dt10, the app through scripts/dev/isolated.sh, a
# private D-Bus session bus started here (refuses the owner's bus), the nested Wayland socket only. If the guard were broken,
# pass 2 would only run `touch` on the marker, or the probe, inside the sandbox.
# Requires: scripts/dev/nested-up.sh running, .dev/build/grassfield-files (apps/files/build-direct.sh), the launch fixtures
# (apps/files/build-direct.sh --tests), dbus-daemon, python3 (writes the download mark).
# Usage: tests/apps/files_dt10.sh [output]   (default GF-REF)   Prints PASS/FAIL per check.
set -uo pipefail

root=$(git -C "$(dirname "$0")" rev-parse --show-toplevel)
dev=$root/.dev
bin=$dev/build/grassfield-files
output=${1:-GF-REF}
sandbox=$dev/files-dt10
folder=$sandbox/folder
marker=$sandbox/marker
busdir=$sandbox/.bus
iso_name=files-dt10
keys=$root/scripts/dev/keys.sh
pointer=$root/scripts/dev/pointer.sh

[[ -x $bin ]] || { echo "FAIL: $bin missing (run apps/files/build-direct.sh)"; exit 1; }
# shellcheck source=../../scripts/dev/pidfile.sh
. "$root/scripts/dev/pidfile.sh"
dev_nested_target "$dev" || { echo "FAIL: no verified nested instance of this tree (run scripts/dev/nested-up.sh as a bare command)"; exit 1; }
command -v dbus-daemon >/dev/null || { echo "FAIL: dbus-daemon not found"; exit 1; }
sock=$DEV_NESTED_SOCK
[[ $sock != "${WAYLAND_DISPLAY:-}" ]] || { echo "FAIL: refusing the main Wayland socket"; exit 1; }
case $folder in "$root"/.dev/files-dt10/*) ;; *) echo "FAIL: unsafe sandbox path"; exit 1 ;; esac
rm -rf -- "$sandbox" "$dev/isolated/$iso_name"
mkdir -p "$folder" "$busdir"

launcher() { # <file> <mode>
  printf '[Desktop Entry]\nType=Application\nName=Invoice\nExec=touch %s\n' "$marker" >"$folder/$1"
  chmod "$2" "$folder/$1"
}
launcher t.desktop 755
launcher u.desktop 644
launcher Invoice.pdf.desktop 644
printf '#!/bin/sh\ntouch %s\n' "$marker" >"$folder/run.sh"
chmod 755 "$folder/run.sh"
# A downloaded program: the probe, executable, with the mark Chromium and Firefox write (no real download).
probe=$dev/build/launch-fixtures/probe
[[ -x $probe ]] || { echo "FAIL: $probe missing (run apps/files/build-direct.sh --tests)"; exit 1; }
cp "$probe" "$folder/Invoice"
chmod 755 "$folder/Invoice"
python3 -I -c 'import os, sys; os.setxattr(sys.argv[1], "user.xdg.origin.url", b"https://downloads.example.org/Invoice")' "$folder/Invoice" \
  || { echo "FAIL: no user extended attributes under $folder"; exit 1; }

env -u DISPLAY -u DBUS_SESSION_BUS_ADDRESS WAYLAND_DISPLAY="$sock" GRASSFIELD_DEV=1 HOME="$dev/isolated/$iso_name/home" \
  setsid dbus-daemon --session --nofork --print-address=1 >"$busdir/address" 2>"$busdir/log" </dev/null &
bus_pid=$!
app=""
cleanup() {
  local pid
  for pid in $app $bus_pid; do
    [[ -n $pid ]] && kill -0 "$pid" 2>/dev/null && kill -- "-$pid" 2>/dev/null
  done
  [[ -n $app ]] && wait "$app" 2>/dev/null
  wait "$bus_pid" 2>/dev/null
}
trap cleanup EXIT
for _ in $(seq 1 50); do [[ -s $busdir/address ]] && break; sleep 0.1; done
bus=$(head -n 1 "$busdir/address" 2>/dev/null)
owner_bus=${DBUS_SESSION_BUS_ADDRESS:-unix:path=${XDG_RUNTIME_DIR:-/run/user/$(id -u)}/bus}
case $bus in unix:path=/tmp/dbus-*) ;; *) echo "FAIL: the private bus did not start ('$bus', see $busdir/log)"; exit 1 ;; esac
[[ $bus != "$owner_bus" && $bus != "unix:path=${XDG_RUNTIME_DIR:-}/bus"* ]] || { echo "FAIL: refusing to run on the owner's session bus"; exit 1; }

fails=0
pass() { echo "PASS: $*"; }
fail() { echo "FAIL: $*"; fails=$((fails + 1)); }

# run_pass <log> <items> <extra env...>: start Files on the folder, open each item (space-separated), quit. A sheet that comes
# up (the downloaded program's) is answered with Return after the double-click hold: Return cancels it.
run_pass() {
  local log=$1 items=$2
  shift 2
  "$pointer" output "$output" abs 960 540 sleep 100 click >/dev/null
  env DBUS_SESSION_BUS_ADDRESS="$bus" "$@" QML_IMPORT_PATH="$root/ui" QT_FORCE_STDERR_LOGGING=1 QT_QPA_PLATFORM=wayland WAYLAND_DISPLAY="$sock" \
    setsid "$root/scripts/dev/isolated.sh" --name "$iso_name" -- "$bin" "$folder" >"$log" 2>&1 </dev/null &
  app=$!
  sleep 3
  kill -0 "$app" 2>/dev/null || { fail "Files exited at start ($log)"; app=""; return; }
  "$pointer" output "$output" abs 1050 600 sleep 200 click >/dev/null
  local name
  for name in $items; do
    sleep 1.2 # the type-to-select buffer expires
    "$keys" "$name"
    sleep 0.4
    # Open (Ctrl+O): Return renames, as in the Finder.
    "$keys" -M ctrl -k o -m ctrl
    sleep 1
    if [[ $name == Invoice ]]; then
      # The sheet holds input for the double-click interval; then Return, which cancels it.
      sleep 1
      "$keys" -k Return
      sleep 1
    fi
  done
  "$keys" -M ctrl -k w -m ctrl
  for _ in $(seq 1 50); do kill -0 "$app" 2>/dev/null || break; sleep 0.1; done
  kill -0 "$app" 2>/dev/null && kill -- "-$app" 2>/dev/null
  app=""
}

run_pass "$sandbox/pass1.log" "t.desktop u.desktop Invoice.pdf.desktop run.sh Invoice" GRASSFIELD_FILES_NO_LAUNCH=1
n=$(grep -c "grassfield-files: open refused (app launcher)" "$sandbox/pass1.log" || true)
[[ $n == 3 ]] && pass "pass 1: the guard refused the three launchers ($n 'open refused')" || fail "pass 1: $n launcher refusals, expected 3 ($sandbox/pass1.log)"
b=$(grep -c "launch blocked" "$sandbox/pass1.log" || true)
[[ $b == 2 ]] && pass "pass 1: the script and the program stopped at the switch (2 'launch blocked')" || fail "pass 1: $b 'launch blocked', expected 2"
a=$(grep -c "grassfield-files: open asked" "$sandbox/pass1.log" || true)
[[ $a == 0 ]] && pass "pass 1: no sheet before the switch" || fail "pass 1: $a sheet(s) asked"

run_pass "$sandbox/pass2.log" "t.desktop u.desktop Invoice.pdf.desktop Invoice"
sleep 2
[[ ! -e $marker ]] && pass "pass 2 (DT-10): no launcher ran (marker absent)" || fail "pass 2 (DT-10): the marker exists: a launcher was run"
[[ ! -e $dev/isolated/$iso_name/home/Invoice.launched && ! -e $folder/Invoice.launched ]] && pass "pass 2 (DT-10): the downloaded program did not run without Open" || fail "pass 2 (DT-10): the downloaded program ran"
n=$(grep -c "grassfield-files: open refused (app launcher)" "$sandbox/pass2.log" || true)
[[ $n == 3 ]] && pass "pass 2: three launcher refusals logged" || fail "pass 2: $n launcher refusals logged, expected 3"
a=$(grep -c "grassfield-files: open asked (program): \"Invoice\" from downloads.example.org" "$sandbox/pass2.log" || true)
[[ $a == 1 ]] && pass "pass 2: the downloaded program's sheet was asked, with its origin" || fail "pass 2: $a sheet(s) asked for Invoice, expected 1"
c=$(grep -c "grassfield-files: open canceled (program)" "$sandbox/pass2.log" || true)
[[ $c == 1 ]] && pass "pass 2: Return canceled it" || fail "pass 2: $c cancel(s) logged, expected 1"

echo "files_dt10: $fails failure(s)"
exit $(( fails > 0 ))
