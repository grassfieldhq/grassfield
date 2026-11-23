#!/usr/bin/env bash
# grassfield-prompter's BlueZ pairing agent (ADR-0035 D-11, owner decision Q9; step 10; spec section 8, A-BT1) on two private
# buses of the test's own: a "session" bus for gcr and a "system" bus with a fake bluetoothd (tests/fixtures/fake-bluez.py,
# owning org.bluez, serving AgentManager1 and Device1 objects as BlueZ 5.87 does), a fake attacker on that bus, a fake shell
# on the bridge's socket (tests/fixtures/prompter-shell.py), a stand-in for Settings' Pair() and, for the shared bound, a
# real libgcr client. Never the owner's buses, bluetoothd or devices: every process runs under env -i with the test's scratch
# directories, the bridge as a development run, which refuses any bus that is not a private test bus. Test codes only.
#  1 refusals at start: --bt-timeout-ms outside a development run
#  2 registration follows the shell: none without a shell, none for a shell that does not draw "bluetooth";
#    RegisterAgent(path, "KeyboardDisplay") then RequestDefaultAgent once it does; the bridge's hello lists bluetooth
#  3 every Agent1 method reaches the shell as kind bluetooth with the device's name (its Alias), address and icon, and its
#    answer reaches bluetoothd: RequestPinCode (the PIN typed), RequestPasskey (6 digits, a number), RequestConfirmation (the
#    passkey as 6 digits), RequestAuthorization (Connect; Decline: Rejected), AuthorizeService (the profile named; a UUID
#    outside the base: "other"), DisplayPinCode (answered at once, the PIN shown), DisplayPasskey (its "entered" sent as
#    progress, the sheet withdrawn once the device is paired; the user's Cancel asks bluetoothd to CancelPairing)
#  4 the device's name: plain (a line feed and a direction override flattened), the address when it has no name
#  5 the user's Cancel of a code or a confirmation: Canceled; bluetoothd's Cancel withdraws the request waiting for its
#    reply, its call answered Canceled, and never a code shown for another device (opus review of step 10, MINOR); a code
#    shown also goes when its device disconnects or is removed; one code shown at a time: a new one withdraws the one
#    before (decision 10-16)
#  6 a caller that is not the owner of org.bluez gets Rejected and the shell sees nothing; its Cancel cancels nothing
#  7 arguments checked: a path outside /org/bluez's devices, a passkey over 999999, a UUID that is not one, a PIN to show
#    that is not letters and digits: Rejected, no sheet
#  8 wrong answers from the shell (a PIN with punctuation, 5 digits for a passkey, a code for a confirmation, ok for a code
#    shown, a check box, a name) cancel the request (Rejected, "cancel"); the shell's refusal is Rejected, never Canceled
#  9 the bound of 8 is shared with gcr's requests (B-05 and the applications' queue): six gcr prompts from three
#    connections, four shown and two waiting unseen; two pairing steps still shown (BlueZ keeps two places), a third
#    Rejected at once (six shown and NetworkManager's two kept fill the 8); a pairing step's freed place goes to the next
#    pairing step, never to a waiting gcr request; the waiting ones shown on their turns, every request answered
# 10 Settings' Pair() (an application without an agent of its own) reaches the bridge's sheet as the default agent
# 11 the shell goes with a request outstanding: Rejected, the agent unregisters (no Release follows, as in BlueZ 5.87); it
#    comes back: registered again
# 12 bluetoothd stops (its Release answered) and restarts with a request outstanding: the shell gets "cancel"; the new one
#    gets RegisterAgent
# 13 a request (and a code shown) past the answer's time (a bridge run with --bt-timeout-ms): withdrawn, Rejected
# 14 no test code, and no sanitizer report (GRASSFIELD_PROMPTER built with build-direct.sh --asan), in the bridge's output
# Needs g++ with the Qt 6 Core and gcr-4 headers (or GRASSFIELD_PROMPTER: a built bridge), dbus-daemon, dbus-send, python3
# with PyGObject (Gio, and Gcr 4 for 9); SKIPs without them, when libdbus cannot reach the buses, and when this process has
# no cgroup of its own to stand for the shell's unit.
#
#   tests/security/bluez_agent.sh              PASS / FAIL lines, exit 0 when all pass
#   tests/security/bluez_agent.sh --mutants    also mutants of the agent's guards, which the checks must catch
set -uo pipefail
umask 077
root=$(git -C "$(dirname "$0")" rev-parse --show-toplevel)
mutants=0
case ${1:-} in
  "") ;;
  --mutants) mutants=1 ;;
  *) echo "usage: bluez_agent.sh [--mutants]" >&2; exit 2 ;;
esac
for tool in dbus-daemon dbus-send python3; do
  command -v "$tool" >/dev/null || { echo "SKIP: bluez_agent needs $tool"; exit 0; }
done
python3 -I -c 'import gi; gi.require_version("Gio", "2.0"); from gi.repository import Gio' 2>/dev/null || { echo "SKIP: bluez_agent needs PyGObject"; exit 0; }
leaf=$(awk -F: '$1 == "0" {print $3}' /proc/self/cgroup | sed 's#.*/##')
[[ -n $leaf ]] || { echo "SKIP: bluez_agent: this process sits at the root of its cgroup tree (no unit to stand for the shell's)"; exit 0; }

# One scenario's processes and scratch directories (globals, so that the EXIT trap can clean up after an interruption).
pids=()
bus_pids=()
tmp=""
d=""
cleanup() {
  local p
  for p in "${pids[@]}"; do kill "$p" 2>/dev/null; done
  for p in "${bus_pids[@]}"; do kill -TERM -- "-$p" 2>/dev/null; done
  wait 2>/dev/null
  [[ -n $tmp ]] && rm -rf "$tmp"
  [[ -n $d ]] && rm -rf "$d"
  pids=()
  bus_pids=()
  tmp=""
  d=""
}

# scenario <bridge binary>: every check below against that bridge; prints PASS/FAIL lines, returns 0 when all passed.
scenario() {
  scenario_body "$@"
  local rc=$?
  cleanup
  return $rc
}

scenario_body() {
  local bridge=$1
  tmp=$(mktemp -d "${GRASSFIELD_TEST_TMP:-${TMPDIR:-/tmp}}/bluez-agent.XXXXXX")
  # Unix socket paths stay under 108 bytes: buses and the bridge's socket in a short directory of their own.
  d=$(mktemp -d /tmp/gfb.XXXXXX)
  local fail=0
  check() { if "$@"; then echo "PASS: $desc"; else echo "FAIL: $desc"; fail=1; fi; }
  wait_until() { local n=$(($1 * 10)); shift; while ((n-- > 0)); do "$@" && return 0; sleep 0.1; done; return 1; }

  # --- the private buses ---------------------------------------------------------------------------------------------
  mkdir -p "$d/services" "$d/run"
  local which
  for which in session system; do
    printf '%s\n' '<!DOCTYPE busconfig PUBLIC "-//freedesktop//DTD D-Bus Bus Configuration 1.0//EN" "http://www.freedesktop.org/standards/dbus/1.0/busconfig.dtd">' \
      '<busconfig>' "  <type>$which</type>" "  <listen>unix:path=$d/$which.sock</listen>" '  <auth>EXTERNAL</auth>' \
      "  <servicedir>$d/services</servicedir>" '  <policy context="default">' '    <allow send_destination="*" eavesdrop="true"/>' \
      '    <allow eavesdrop="true"/>' '    <allow own="*"/>' '  </policy>' '</busconfig>' >"$d/$which.conf"
    setsid env -i PATH="$PATH" HOME="$d" XDG_RUNTIME_DIR="$d/run" dbus-daemon --config-file="$d/$which.conf" --nofork --print-address=1 \
      >"$d/$which.address" 2>"$d/$which.log" </dev/null &
    bus_pids+=("$!")
    wait_until 5 test -s "$d/$which.address" || { echo "SKIP: bluez_agent: no private dbus-daemon (Unix sockets unavailable?)"; return 0; }
  done
  local bus sysbus
  bus=$(head -n 1 "$d/session.address")
  sysbus=$(head -n 1 "$d/system.address")
  dbus-send --bus="$sysbus" --print-reply --dest=org.freedesktop.DBus /org/freedesktop/DBus org.freedesktop.DBus.GetId >/dev/null 2>&1 \
    || { echo "SKIP: bluez_agent: libdbus cannot reach the private bus"; return 0; }

  local run_env=(env -i PATH="$PATH" HOME="$d" XDG_RUNTIME_DIR="$d/run" DBUS_SESSION_BUS_ADDRESS="$bus" DBUS_SYSTEM_BUS_ADDRESS="$sysbus"
    GF_TEST_BUS=1 GF_TEST_BUS_DIR="$d" LC_ALL=C.UTF-8)
  local sock=$d/run/grassfield/prompter.sock
  local shell_py=$root/tests/fixtures/prompter-shell.py bz_py=$root/tests/fixtures/fake-bluez.py client_py=$root/tests/fixtures/prompter-client.py

  # --- 1 refusals at start ---------------------------------------------------------------------------------------------
  desc="--bt-timeout-ms is refused outside a development run (exit 3)"
  "${run_env[@]}" GRASSFIELD_SESSION=1 "$bridge" --socket "$sock" --bt-timeout-ms 1000 >"$tmp/r1.log" 2>&1
  check test $? -eq 3

  # helpers
  start_bridge() { # <tag> [args...]
    local tag=$1
    shift
    "${run_env[@]}" GRASSFIELD_DEV=1 "$bridge" "$@" >"$d/$tag.log" 2>&1 &
    bridge_pid=$!
    pids+=("$bridge_pid")
  }
  shell_up() { # <tag> <socket>
    mkfifo "$d/$1.cmd"
    python3 -I "$shell_py" --socket "$2" --log "$d/$1.shell" --commands "$d/$1.cmd" </dev/null >/dev/null 2>&1 &
    pids+=("$!")
    wait_until 5 grep -q '^#connect' "$d/$1.shell" 2>/dev/null
  }
  bz_up() { # <tag> [--attacker]
    mkfifo "$d/$1.cmd"
    "${run_env[@]}" python3 -I "$bz_py" --log "$d/$1.bz" --commands "$d/$1.cmd" "${@:2}" </dev/null >"$d/$1.err" 2>&1 &
    pids+=("$!")
    wait_until 5 grep -q '^#ready' "$d/$1.bz" 2>/dev/null
  }
  say() { timeout 5 bash -c 'printf "%s\n" "$2" >"$1"' _ "$d/$1.cmd" "$2"; }
  has() { grep -q -- "$3" "$d/$1.$2" 2>/dev/null; }
  count() { grep -c -- "$3" "$d/$1.$2" 2>/dev/null; }
  last_prompt() { # <shell tag> <python expression on the last prompt line m>
    grep '"type":"prompt"' "$d/$1.shell" | tail -n 1 | python3 -I -c "import json,sys; m=json.loads(sys.stdin.read()); print($2)"
  }
  last_id() { last_prompt "$1" 'm["id"]'; }
  prompts() { count "$1" shell '"type":"prompt"'; }
  # next_prompt <shell tag> <count before>: waits for one more prompt
  next_prompt() { wait_until 10 bash -c '[[ $(grep -c "\"type\":\"prompt\"" "$1") -gt $2 ]]' _ "$d/$1.shell" "$2"; }
  cancelled() { grep -q "{\"id\":\"$2\",\"type\":\"cancel\"}" "$d/$1.shell"; }

  # --- 2 registration follows the shell --------------------------------------------------------------------------------
  bz_up bz
  say bz "device AA_BB_CC_DD_EE_01 alias=Desk-Keys icon=input-keyboard"
  say bz "device AA_BB_CC_DD_EE_02 alias=Phone icon=phone"
  start_bridge main --socket "$sock" --peer-unit "$leaf"
  local main_pid=$bridge_pid
  wait_until 5 test -S "$sock"
  wait_until 5 grep -q "Bluetooth pairing agent ready on" "$d/main.log"
  local agent_name
  agent_name=$(sed -n 's/^grassfield-prompter: Bluetooth pairing agent ready on \(:[0-9.]*\) .*/\1/p' "$d/main.log")
  sleep 0.3
  desc="without a shell the agent is not registered with bluetoothd"
  check bash -c '[[ -n $2 ]] && ! grep -q "^#register" "$1"' _ "$d/bz.bz" "$agent_name"
  shell_up old "$sock"
  say old "hello password confirm nm"
  sleep 0.5
  desc="a shell that does not draw \"bluetooth\": still not registered"
  check bash -c '! grep -q "^#register" "$1"' _ "$d/bz.bz"
  say old close
  wait_until 5 grep -q "shell gone" "$d/main.log"
  shell_up s "$sock"
  say s "hello password confirm bluetooth"
  desc="a shell that draws \"bluetooth\" says hello: RegisterAgent(path, KeyboardDisplay) then RequestDefaultAgent, from the bridge's own system bus connection"
  check wait_until 5 bash -c 'grep -qx "#register $2 /org/grassfield/prompter/BluetoothAgent KeyboardDisplay" "$1" && grep -qx "#default $2 /org/grassfield/prompter/BluetoothAgent" "$1"' _ "$d/bz.bz" "$agent_name"
  desc="...and the bridge's hello lists bluetooth"
  check has s shell '"kinds":\["password","confirm","nm","kio","bluetooth"\]'

  # --- 3 every method ---------------------------------------------------------------------------------------------------
  local n
  n=$(prompts s)
  say bz "pin b1 AA_BB_CC_DD_EE_01"
  next_prompt s "$n"
  desc="RequestPinCode: kind bluetooth, mode pin, the device's alias, address and icon, no requester object"
  check test "$(last_prompt s '"|".join((m["kind"], m["pairing"]["mode"], m["device"]["name"], m["device"]["address"], m["device"]["icon"], ",".join(sorted(m))))')" \
    = "bluetooth|pin|Desk-Keys|AA:BB:CC:DD:EE:01|keyboard|device,id,kind,pairing,type"
  say s "answer last ok 12ab34"
  desc="...the PIN typed reaches bluetoothd"
  check wait_until 10 grep -qx 'b1 ok 12ab34' "$d/bz.bz"
  n=$(prompts s)
  say bz "passkey b2 AA_BB_CC_DD_EE_01"
  next_prompt s "$n"
  desc="RequestPasskey: mode passkey"
  check test "$(last_prompt s 'm["pairing"]["mode"]')" = passkey
  say s "answer last ok 012345"
  desc="...6 digits typed reach bluetoothd as the number 12345"
  check wait_until 10 grep -qx 'b2 ok 12345' "$d/bz.bz"
  n=$(prompts s)
  say bz "confirm b3 AA_BB_CC_DD_EE_02 7"
  next_prompt s "$n"
  desc="RequestConfirmation: mode confirm, the passkey shown as 6 digits (000007)"
  check test "$(last_prompt s '"|".join((m["pairing"]["mode"], m["pairing"]["code"], m["device"]["icon"]))')" = "confirm|000007|phone"
  say s "confirm last ok"
  desc="...Connect: an empty reply"
  check wait_until 10 grep -qx 'b3 ok' "$d/bz.bz"
  n=$(prompts s)
  say bz "authorize b4 AA_BB_CC_DD_EE_02"
  next_prompt s "$n"
  desc="RequestAuthorization: mode authorize"
  check test "$(last_prompt s 'm["pairing"]["mode"]')" = authorize
  say s "confirm last ok"
  desc="...Connect: an empty reply"
  check wait_until 10 grep -qx 'b4 ok' "$d/bz.bz"
  n=$(prompts s)
  say bz "authorize b5 AA_BB_CC_DD_EE_02"
  next_prompt s "$n"
  say s "confirm last cancel"
  desc="...Decline: Rejected"
  check wait_until 10 grep -qx 'b5 error org.bluez.Error.Rejected' "$d/bz.bz"
  n=$(prompts s)
  say bz "service b6 AA_BB_CC_DD_EE_02 0000110B-0000-1000-8000-00805F9B34FB"
  next_prompt s "$n"
  desc="AuthorizeService: mode authorize-service, A2DP named \"audio\", the UUID in lower case"
  check test "$(last_prompt s '"|".join((m["pairing"]["mode"], m["pairing"]["service"], m["pairing"]["uuid"]))')" = "authorize-service|audio|0000110b-0000-1000-8000-00805f9b34fb"
  say s "confirm last ok"
  desc="...Connect: an empty reply"
  check wait_until 10 grep -qx 'b6 ok' "$d/bz.bz"
  n=$(prompts s)
  say bz "service b7 AA_BB_CC_DD_EE_02 03b80e5a-ede8-4b33-a751-6ce34ec4c700"
  next_prompt s "$n"
  desc="...a UUID outside the Bluetooth base: \"other\""
  check test "$(last_prompt s 'm["pairing"]["service"]')" = other
  say s "confirm last cancel"
  desc="...Decline: Rejected"
  check wait_until 10 grep -qx 'b7 error org.bluez.Error.Rejected' "$d/bz.bz"
  n=$(prompts s)
  say bz "display-pin b8 AA_BB_CC_DD_EE_01 482913"
  desc="DisplayPinCode: answered at once (bluetoothd then hands the PIN to the controller), before any answer of the shell"
  check wait_until 10 grep -qx 'b8 ok' "$d/bz.bz"
  next_prompt s "$n"
  desc="...the shell shows it: mode display-pin, the code"
  check test "$(last_prompt s '"|".join((m["pairing"]["mode"], m["pairing"]["code"]))')" = "display-pin|482913"
  local cid
  cid=$(last_id s)
  say bz "paired AA_BB_CC_DD_EE_01"
  desc="...the device reported paired: the shell gets \"cancel $cid\""
  check wait_until 10 cancelled s "$cid"
  n=$(prompts s)
  say bz "display-passkey AA_BB_CC_DD_EE_02 42 0"
  next_prompt s "$n"
  cid=$(last_id s)
  desc="DisplayPasskey: mode display-passkey, the code 000042, 0 digits typed"
  check test "$(last_prompt s '"|".join((m["pairing"]["mode"], m["pairing"]["code"], str(m["pairing"]["entered"])))')" = "display-passkey|000042|0"
  say bz "display-passkey AA_BB_CC_DD_EE_02 42 1"
  say bz "display-passkey AA_BB_CC_DD_EE_02 42 3"
  say bz "display-passkey AA_BB_CC_DD_EE_02 42 3"
  desc="...each digit typed on the device: a progress line (1, then 3; the same count twice sends nothing), never a new prompt"
  check wait_until 10 bash -c 'grep -qx "{\"entered\":1,\"id\":\"$2\",\"type\":\"progress\"}" "$1" && grep -qx "{\"entered\":3,\"id\":\"$2\",\"type\":\"progress\"}" "$1" && [[ $(grep -c "\"type\":\"progress\"" "$1") == 2 && $(grep -c "\"type\":\"prompt\"" "$1") == $3 ]]' _ "$d/s.shell" "$cid" "$((n + 1))"
  say s "answer $cid cancel"
  desc="...the user's Cancel of a code shown: bluetoothd is asked to stop the pairing (CancelPairing)"
  check wait_until 10 grep -q "^#cancelpairing AA_BB_CC_DD_EE_02 $agent_name" "$d/bz.bz"
  n=$(prompts s)
  say bz "display-passkey AA_BB_CC_DD_EE_02 42 4"
  next_prompt s "$n"
  desc="...and a late DisplayPasskey of that ended code shows it again as a new request, never as progress of the old one"
  check bash -c '! grep -q "{\"entered\":4,\"id\":\"$2\"" "$1"' _ "$d/s.shell" "$cid"
  cid=$(last_id s)
  say bz "paired AA_BB_CC_DD_EE_02"
  wait_until 10 cancelled s "$cid"

  # --- 4 the device's name ------------------------------------------------------------------------------------------------
  say bz "device AA_BB_CC_DD_EE_03 aliashex=4b65790ae280ae6f6e65 icon=weird-icon"
  n=$(prompts s)
  say bz "authorize n1 AA_BB_CC_DD_EE_03"
  next_prompt s "$n"
  desc="an alias with a line feed and a direction override arrives flattened; an unknown icon is none"
  check test "$(last_prompt s 'm["device"]["name"].encode().hex() + "|" + m["device"]["icon"]')" = "4b6579206f6e65|"
  say s "confirm last cancel"
  n=$(prompts s)
  say bz "authorize n2 /org/bluez/hci0/dev_AA_BB_CC_DD_EE_99"
  next_prompt s "$n"
  desc="a device whose properties cannot be read is named by its address"
  check test "$(last_prompt s 'm["device"]["name"]')" = "AA:BB:CC:DD:EE:99"
  say s "confirm last cancel"
  wait_until 10 grep -q '^n2 error' "$d/bz.bz"

  # --- 5 cancels ----------------------------------------------------------------------------------------------------------
  local tag
  for tag in c1 c2 c3; do
    n=$(prompts s)
    case $tag in
      c1) say bz "pin $tag AA_BB_CC_DD_EE_01" ;;
      c2) say bz "passkey $tag AA_BB_CC_DD_EE_01" ;;
      c3) say bz "confirm $tag AA_BB_CC_DD_EE_01 135790" ;;
    esac
    next_prompt s "$n"
    say s "answer last cancel"
    wait_until 10 grep -q "^$tag " "$d/bz.bz"
  done
  desc="the user's Cancel of a PIN, a passkey and a confirmation: Canceled for each"
  check bash -c 'for t in c1 c2 c3; do grep -qx "$t error org.bluez.Error.Canceled" "$1" || exit 1; done' _ "$d/bz.bz"
  n=$(prompts s)
  say bz "confirm c4 AA_BB_CC_DD_EE_01 1"
  next_prompt s "$n"
  cid=$(last_id s)
  say bz "cancel"
  desc="bluetoothd's Cancel: the shell gets \"cancel $cid\", the call Canceled"
  check wait_until 10 bash -c 'grep -q "{\"id\":\"$2\",\"type\":\"cancel\"}" "$1" && grep -qx "c4 error org.bluez.Error.Canceled" "$3"' _ "$d/s.shell" "$cid" "$d/bz.bz"
  say s "confirm $cid ok"
  desc="...and a late answer is ignored"
  check wait_until 5 grep -q "answer to $cid ignored: not outstanding" "$d/main.log"
  # bluetoothd's Cancel ends the call waiting for its reply, never a code shown for another device.
  say bz "device AA_BB_CC_DD_EE_09 alias=Remote"
  n=$(prompts s)
  say bz "display-passkey AA_BB_CC_DD_EE_09 314159 0"
  next_prompt s "$n"
  local shown
  shown=$(last_id s)
  n=$(prompts s)
  say bz "confirm h1 AA_BB_CC_DD_EE_01 5"
  next_prompt s "$n"
  cid=$(last_id s)
  say bz "cancel"
  wait_until 10 grep -qx "h1 error org.bluez.Error.Canceled" "$d/bz.bz"
  sleep 0.5
  desc="bluetoothd's Cancel (for device 01's confirmation) withdraws that request only: the code shown for device 09 stays"
  check bash -c 'grep -q "{\"id\":\"$2\",\"type\":\"cancel\"}" "$1" && ! grep -q "{\"id\":\"$3\",\"type\":\"cancel\"}" "$1"' _ "$d/s.shell" "$cid" "$shown"
  say bz "connected AA_BB_CC_DD_EE_09 false"
  desc="...that code goes when its device disconnects"
  check wait_until 10 cancelled s "$shown"
  say bz "connected AA_BB_CC_DD_EE_09 true"
  n=$(prompts s)
  say bz "display-pin z1 AA_BB_CC_DD_EE_09 271828"
  next_prompt s "$n"
  shown=$(last_id s)
  say bz "remove AA_BB_CC_DD_EE_09"
  desc="a code shown goes when its device is removed (InterfacesRemoved)"
  check wait_until 10 cancelled s "$shown"
  n=$(prompts s)
  say bz "display-passkey AA_BB_CC_DD_EE_01 161803 0"
  next_prompt s "$n"
  local first second
  first=$(last_id s)
  n=$(prompts s)
  say bz "display-pin z2 AA_BB_CC_DD_EE_02 577215"
  next_prompt s "$n"
  second=$(last_id s)
  n=$(prompts s)
  say bz "display-passkey AA_BB_CC_DD_EE_03 141421 0"
  next_prompt s "$n"
  desc="one code shown at a time: each new one (another device) withdraws the one before"
  check wait_until 10 bash -c 'grep -q "{\"id\":\"$2\",\"type\":\"cancel\"}" "$1" && grep -q "{\"id\":\"$3\",\"type\":\"cancel\"}" "$1"' _ "$d/s.shell" "$first" "$second"
  shown=$(last_id s)
  say bz "paired AA_BB_CC_DD_EE_03"
  wait_until 10 cancelled s "$shown"

  # --- 6 a caller that is not bluetoothd ----------------------------------------------------------------------------------
  bz_up att --attacker
  say att "target $agent_name"
  n=$(prompts s)
  say att "authorize a1 AA_BB_CC_DD_EE_01"
  say att "pin a2 AA_BB_CC_DD_EE_01"
  desc="a caller that does not own org.bluez gets Rejected (RequestAuthorization, RequestPinCode)"
  check wait_until 10 bash -c 'grep -qx "a1 error org.bluez.Error.Rejected" "$1" && grep -qx "a2 error org.bluez.Error.Rejected" "$1"' _ "$d/att.bz"
  sleep 0.3
  desc="...and the shell was shown nothing"
  check test "$(prompts s)" = "$n"
  desc="...the journal names the refusal"
  check grep -q "refused RequestAuthorization from :.*: not the owner of org.bluez" "$d/main.log"
  say bz "confirm a3 AA_BB_CC_DD_EE_01 5"
  next_prompt s "$n"
  say att "cancel"
  sleep 0.5
  say s "confirm last ok"
  desc="the attacker's Cancel cancels nothing: bluetoothd's request still gets its answer"
  check wait_until 10 grep -qx 'a3 ok' "$d/bz.bz"
  say att quit

  # --- 7 arguments checked ------------------------------------------------------------------------------------------------
  n=$(prompts s)
  say bz "authorize v1 /org/freedesktop/NetworkManager/Devices/1"
  say bz "authorize v2 /org/bluez/hci0/dev_aa_bb_cc_dd_ee_01"
  say bz "confirm v3 AA_BB_CC_DD_EE_01 1000000"
  say bz "service v4 AA_BB_CC_DD_EE_01 not-a-uuid"
  say bz "display-pin v5 AA_BB_CC_DD_EE_01 12;34"
  desc="a path outside bluetoothd's devices (or in lower case), a passkey over 999999, a UUID that is not one, a PIN to show with punctuation: Rejected"
  check wait_until 10 bash -c 'for t in v1 v2 v3 v4 v5; do grep -qx "$t error org.bluez.Error.Rejected" "$1" || exit 1; done' _ "$d/bz.bz"
  sleep 0.3
  desc="...and the shell was shown none of them"
  check test "$(prompts s)" = "$n"

  # --- 8 wrong answers ----------------------------------------------------------------------------------------------------
  local line wrong_ids=()
  for tag in w1 w2 w3 w4 w5 w6; do
    n=$(prompts s)
    case $tag in
      w1) say bz "pin $tag AA_BB_CC_DD_EE_01" ;;
      w2) say bz "passkey $tag AA_BB_CC_DD_EE_01" ;;
      w3 | w5 | w6) say bz "confirm $tag AA_BB_CC_DD_EE_01 3" ;;
      w4) say bz "display-pin $tag AA_BB_CC_DD_EE_01 000123" ;;
    esac
    next_prompt s "$n"
    cid=$(last_id s)
    case $tag in
      w1) line="{\"type\":\"answer\",\"id\":\"$cid\",\"result\":\"ok\",\"password\":\"12-34\"}" ;;
      w2) line="{\"type\":\"answer\",\"id\":\"$cid\",\"result\":\"ok\",\"password\":\"12345\"}" ;;
      w3) line="{\"type\":\"answer\",\"id\":\"$cid\",\"result\":\"ok\",\"password\":\"123456\"}" ;;
      w4) line="{\"type\":\"answer\",\"id\":\"$cid\",\"result\":\"ok\"}" ;;
      w5) line="{\"type\":\"answer\",\"id\":\"$cid\",\"result\":\"ok\",\"choice\":true}" ;;
      w6) line="{\"type\":\"answer\",\"id\":\"$cid\",\"result\":\"ok\",\"identity\":\"eve\"}" ;;
    esac
    say s "raw $line"
    wrong_ids+=("$cid")
    wait_until 10 cancelled s "$cid"
  done
  desc="a PIN with punctuation, 5 digits for a passkey, a code, a check box or a name for a confirmation: each Rejected"
  check bash -c 'for t in w1 w2 w3 w5 w6; do grep -qx "$t error org.bluez.Error.Rejected" "$1" || exit 1; done' _ "$d/bz.bz"
  desc="...each, and ok for a code shown, withdrawn from the shell (\"cancel\")"
  check bash -c 'f=$1; shift; for id in "$@"; do grep -q "{\"id\":\"$id\",\"type\":\"cancel\"}" "$f" || exit 1; done' _ "$d/s.shell" "${wrong_ids[@]}"
  n=$(prompts s)
  say bz "confirm r0 AA_BB_CC_DD_EE_01 4"
  next_prompt s "$n"
  say s "confirm last refused"
  desc="the shell's refusal (\"refused\", its bound) is Rejected, never the user's Canceled"
  check wait_until 10 grep -qx "r0 error org.bluez.Error.Rejected" "$d/bz.bz"

  # --- 9 the bound is shared with gcr -------------------------------------------------------------------------------------
  # B-05 (bridges/prompter/src/Requests.h) and its amendment (the applications' queue, owner decision 2026-11-22): of the
  # shell's 8 places NetworkManager and BlueZ keep two each; the applications' gcr prompts hold at most four (one connection
  # two), the others wait in the bridge, unseen and holding no place; bluetoothd's requests never wait.
  if python3 -I -c 'import gi; gi.require_version("Gcr", "4"); from gi.repository import Gcr' 2>/dev/null; then
    # ids_since <shell log line> <kind>: the ids of the prompts of that kind the shell got after that line, oldest first
    ids_since() {
      tail -n +"$(($1 + 1))" "$d/s.shell" | grep '"type":"prompt"' \
        | python3 -I -c 'import json,sys; [print(m["id"]) for m in map(json.loads, sys.stdin) if m["kind"] == sys.argv[1]]' "$2"
    }
    local from waits turns g bt=()
    from=$(wc -l <"$d/s.shell")
    n=$(prompts s)
    waits=$(count main log "waits for a place")
    turns=$(count main log "a place is free, its turn")
    # Three connections with two prompts each: whichever four are shown, each waiting one is held back by the applications'
    # share only (its connection shows fewer than two), so a place BlueZ frees would fit it if the reserve were not kept.
    for g in g1 g2 g3; do
      "${run_env[@]}" python3 -I "$client_py" many 2 >"$d/$g.out" 2>&1 &
      pids+=("$!")
    done
    desc="six gcr prompts from three connections: the shell gets the applications' four, the other two wait in the bridge"
    check wait_until 15 bash -c '[[ $(( $(grep -c "\"type\":\"prompt\"" "$1") - $2 )) == 4 && $(( $(grep -c "waits for a place" "$3") - $4 )) == 2 ]]' \
      _ "$d/s.shell" "$n" "$d/main.log" "$waits"
    say bz "authorize q1 AA_BB_CC_DD_EE_01"
    say bz "authorize q2 AA_BB_CC_DD_EE_01"
    desc="...two pairing steps still reach the shell: BlueZ keeps its two places, which the waiting gcr requests do not hold"
    check wait_until 10 bash -c '[[ $(( $(grep -c "\"type\":\"prompt\"" "$1") - $2 )) == 6 ]]' _ "$d/s.shell" "$n"
    say bz "authorize q3 AA_BB_CC_DD_EE_02"
    desc="...a third gets Rejected at once, never queued: six shown and NetworkManager's two kept fill the shell's 8"
    check wait_until 10 grep -qx "q3 error org.bluez.Error.Rejected" "$d/bz.bz"
    sleep 0.3
    desc="...the shell saw nothing of it, and no gcr request was answered or refused meanwhile"
    check bash -c '[[ $(( $(grep -c "\"type\":\"prompt\"" "$1") - $2 )) == 6 ]] && ! cat "$3" "$4" "$5" | grep -q -e cancelled -e password=' \
      _ "$d/s.shell" "$n" "$d/g1.out" "$d/g2.out" "$d/g3.out"
    mapfile -t bt < <(ids_since "$from" bluetooth)
    printf '%s\n' "${bt[@]:0:1}" >"$d/answered"
    say s "answer ${bt[0]:-none} cancel"
    wait_until 10 grep -qx "q1 error org.bluez.Error.Rejected" "$d/bz.bz"
    sleep 1
    desc="a pairing step declined (q1, Rejected) leaves its place to BlueZ: no waiting gcr request takes it"
    check bash -c 'grep -qx "q1 error org.bluez.Error.Rejected" "$1" && [[ $(( $(grep -c "\"type\":\"prompt\"" "$2") - $3 )) == 6 && $(grep -c "a place is free, its turn" "$4") == "$5" ]]' \
      _ "$d/bz.bz" "$d/s.shell" "$n" "$d/main.log" "$turns"
    say bz "authorize q4 AA_BB_CC_DD_EE_01"
    desc="...the next pairing step (q4) gets it, shown at once"
    check wait_until 10 bash -c '[[ $(( $(grep -c "\"type\":\"prompt\"" "$1") - $2 )) == 7 ]]' _ "$d/s.shell" "$n"
    # Every prompt answered "cancel" as it reaches the shell: each gcr answer gives its place to a waiting gcr request.
    for _ in $(seq 1 30); do
      for cid in $(ids_since "$from" password) $(ids_since "$from" bluetooth); do
        grep -qx "$cid" "$d/answered" && continue
        echo "$cid" >>"$d/answered"
        say s "answer $cid cancel"
      done
      [[ $(cat "$d/g1.out" "$d/g2.out" "$d/g3.out" | grep -c cancelled) -ge 6 ]] && break
      sleep 0.5
    done
    desc="...the two waiting gcr requests are shown on their turns, and every request gets its answer (gcr: six cancelled; bluetooth: q2 and q4 Rejected)"
    check wait_until 10 bash -c '[[ $(cat "$1" "$2" "$3" | grep -c cancelled) == 6 && $(( $(grep -c "a place is free, its turn" "$4") - $5 )) == 2 ]] && for t in q2 q4; do grep -qx "$t error org.bluez.Error.Rejected" "$6" || exit 1; done' \
      _ "$d/g1.out" "$d/g2.out" "$d/g3.out" "$d/main.log" "$turns" "$d/bz.bz"
  else
    echo "SKIP: bluez_agent: the shared bound needs PyGObject with Gcr 4"
  fi

  # --- 10 Settings' Pair() reaches the sheet -------------------------------------------------------------------------------
  say bz "device AA_BB_CC_DD_EE_04 alias=Headset icon=audio-headset"
  say bz "pairmode confirm 654321"
  n=$(prompts s)
  "${run_env[@]}" dbus-send --bus="$sysbus" --print-reply --reply-timeout=20000 --dest=org.bluez /org/bluez/hci0/dev_AA_BB_CC_DD_EE_04 org.bluez.Device1.Pair \
    >"$d/pair.out" 2>&1 &
  local pair_pid=$!
  pids+=("$pair_pid")
  next_prompt s "$n"
  desc="Settings' Pair() (no agent of its own) asks the default agent: the bridge's sheet, mode confirm, code 654321"
  check bash -c 'grep -q "^#pair AA_BB_CC_DD_EE_04 $2 confirm" "$1" && [[ $3 == "confirm|654321|Headset" ]]' _ "$d/bz.bz" "$agent_name" \
    "$(last_prompt s '"|".join((m["pairing"]["mode"], m["pairing"]["code"], m["device"]["name"]))')"
  say s "confirm last ok"
  wait "$pair_pid" 2>/dev/null
  desc="...Connect: Pair() succeeds"
  check bash -c 'grep -qx "#pair-done AA_BB_CC_DD_EE_04 ok" "$1" && grep -q "method return" "$2"' _ "$d/bz.bz" "$d/pair.out"

  # --- 11 the shell goes and comes back -----------------------------------------------------------------------------------
  n=$(prompts s)
  say bz "pin g1 AA_BB_CC_DD_EE_01"
  next_prompt s "$n"
  say s close
  desc="the shell goes with a request outstanding: Rejected"
  check wait_until 10 grep -qx "g1 error org.bluez.Error.Rejected" "$d/bz.bz"
  desc="...the agent unregisters from bluetoothd (which sends no Release for it, as BlueZ 5.87)"
  check wait_until 10 bash -c 'grep -qx "#unregister $2 /org/grassfield/prompter/BluetoothAgent" "$1" && ! grep -q "^#release-sent" "$1" && ! grep -q "Release from bluetoothd" "$3"' _ "$d/bz.bz" "$agent_name" "$d/main.log"
  say bz "target $agent_name"
  say bz "authorize g2 AA_BB_CC_DD_EE_01"
  desc="a call that still reaches the unregistered agent meanwhile: Rejected"
  check wait_until 10 grep -qx "g2 error org.bluez.Error.Rejected" "$d/bz.bz"
  say bz "target -"
  shell_up s2 "$sock"
  say s2 "hello password confirm bluetooth"
  desc="the shell comes back: registered again, the default agent again"
  check wait_until 10 bash -c '[[ $(grep -c "^#register $2 " "$1") == 2 && $(grep -c "^#default $2 " "$1") == 2 ]]' _ "$d/bz.bz" "$agent_name"

  # --- 12 bluetoothd restarts ---------------------------------------------------------------------------------------------
  n=$(prompts s2)
  say bz "confirm r1 AA_BB_CC_DD_EE_01 8"
  next_prompt s2 "$n"
  cid=$(last_id s2)
  say bz release
  desc="a stopping bluetoothd's Release is answered"
  check wait_until 5 grep -q "Release from bluetoothd" "$d/main.log"
  say bz quit
  desc="bluetoothd leaves with a request outstanding: the shell gets \"cancel $cid\""
  check wait_until 10 cancelled s2 "$cid"
  bz_up bz2
  say bz2 "device AA_BB_CC_DD_EE_05 alias=Again"
  desc="a new bluetoothd on the bus: the agent registers with it and asks to be the default"
  check wait_until 10 bash -c 'grep -qx "#register $2 /org/grassfield/prompter/BluetoothAgent KeyboardDisplay" "$1" && grep -qx "#default $2 /org/grassfield/prompter/BluetoothAgent" "$1"' _ "$d/bz2.bz" "$agent_name"
  n=$(prompts s2)
  say bz2 "passkey r2 AA_BB_CC_DD_EE_05"
  next_prompt s2 "$n"
  say s2 "answer last ok 246802"
  desc="...and answers it"
  check wait_until 10 grep -qx 'r2 ok 246802' "$d/bz2.bz"
  say s2 close
  wait_until 10 grep -q "#unregister $agent_name" "$d/bz2.bz"
  kill "$main_pid" 2>/dev/null

  # --- 13 the answer's time -----------------------------------------------------------------------------------------------
  start_bridge short --socket "$d/run/grassfield/short.sock" --peer-unit "$leaf" --bt-timeout-ms 1500
  wait_until 5 test -S "$d/run/grassfield/short.sock"
  shell_up s3 "$d/run/grassfield/short.sock"
  say s3 "hello password confirm bluetooth"
  wait_until 10 bash -c '[[ $(grep -c "^#default" "$1") -ge 2 ]]' _ "$d/bz2.bz"
  say bz2 "authorize t1 AA_BB_CC_DD_EE_05"
  wait_until 10 grep -q '"kind":"bluetooth"' "$d/s3.shell"
  cid=$(last_id s3)
  desc="a request left unanswered past the answer's time: withdrawn from the shell (\"cancel $cid\"), Rejected"
  check wait_until 10 bash -c 'grep -q "{\"id\":\"$2\",\"type\":\"cancel\"}" "$1" && grep -qx "t1 error org.bluez.Error.Rejected" "$3"' _ "$d/s3.shell" "$cid" "$d/bz2.bz"
  n=$(prompts s3)
  say bz2 "display-passkey AA_BB_CC_DD_EE_05 77 0"
  next_prompt s3 "$n"
  cid=$(last_id s3)
  desc="...and a code shown past it: withdrawn (\"cancel $cid\")"
  check wait_until 10 cancelled s3 "$cid"

  # --- 14 nothing secret in the journal -----------------------------------------------------------------------------------
  desc="no test code in the bridge's output"
  check bash -c '! grep -q -e 12ab34 -e 012345 -e 482913 -e 000042 -e 654321 -e 246802 -e 135790 -e 000007 -e 000123 -e 12-34 -e 314159 -e 271828 -e 161803 -e 577215 -e 141421 "$1" "$2"' _ "$d/main.log" "$d/short.log"
  desc="no sanitizer report in the bridge's output (a bridge built with build-direct.sh --asan)"
  check bash -c '! grep -q -e "AddressSanitizer" -e "runtime error:" "$1" "$2"' _ "$d/main.log" "$d/short.log"
  return $fail
}

bridge=${GRASSFIELD_PROMPTER:-}
tmpb=$(mktemp -d "${GRASSFIELD_TEST_TMP:-${TMPDIR:-/tmp}}/bluez-agent-bin.XXXXXX")
trap 'cleanup; rm -rf "$tmpb"' EXIT
trap 'exit 130' INT
trap 'exit 143' TERM
if [[ -z $bridge ]]; then
  command -v g++ >/dev/null && pkg-config --exists Qt6Core gcr-4 libsecret-1 2>/dev/null || { echo "SKIP: bluez_agent needs g++, Qt 6 Core, gcr-4 and libsecret"; exit 0; }
  "$root/bridges/prompter/build-direct.sh" --out "$tmpb/bin" >"$tmpb/build.log" 2>&1 || { cat "$tmpb/build.log"; echo "FAIL: the bridge builds"; exit 1; }
  bridge=$tmpb/bin/grassfield-prompter
fi
scenario "$bridge"
rc=$?

if ((mutants)); then
  # Each mutant removes one guard of the agent (file under bridges/prompter/src, text that occurs once, replacement): the
  # scenario must fail on every one.
  while IFS= read -r spec; do
    [[ -n $spec ]] || continue
    IFS='#' read -r -a f <<<"$spec"
    name=${f[0]}
    m=$tmpb/mut
    rm -rf "$m"
    mkdir -p "$m/bridges" "$m/apps" "$m/ui/i18n"
    cp -a "$root/bridges/prompter" "$m/bridges/"
    cp "$root/apps/runmode.h" "$root/apps/testbus.h" "$m/apps/"
    cp "$root/ui/i18n/translationloader.h" "$m/ui/i18n/"
    cp "$root/VERSION" "$m/"
    git -C "$m" init -q
    if ! python3 -I - "$m/bridges/prompter/src/${f[1]}" "${f[2]}" "${f[3]}" <<'PY'; then echo "MUTANT $name: NOT APPLIED"; rc=1; continue; fi
import sys
p, a, b = sys.argv[1], sys.argv[2].replace("\\n", "\n"), sys.argv[3].replace("\\n", "\n")
s = open(p).read()
if s.count(a) != 1:
    sys.exit(3)
open(p, "w").write(s.replace(a, b))
PY
    "$m/bridges/prompter/build-direct.sh" --out "$m/bin" >"$m/build.log" 2>&1 || { echo "MUTANT $name: DOES NOT BUILD"; rc=1; continue; }
    if scenario "$m/bin/grassfield-prompter" >"$m/run.log" 2>&1; then echo "MUTANT $name: NOT CAUGHT"; rc=1; else echo "MUTANT $name: CAUGHT ($(grep -c '^FAIL' "$m/run.log") failing)"; fi
  done <<'EOF_MUTANTS'
automatic-yes (an authorization answered without the shell)#BtAgent.cpp#            begin(bt::Mode::Authorize, devicePath, owner, address, invocation, QString(), 0);#            g_dbus_method_invocation_return_value(invocation, nullptr);
sender-not-checked#BtAgent.cpp#        if (owner.isEmpty() || sender != owner) {#        if (false) {
stays-registered-without-a-shell#BtAgent.cpp#        endAll(bt::kErrorRejected, QStringLiteral("no shell to ask"), false);\n        sendUnregister();#        endAll(bt::kErrorRejected, QStringLiteral("no shell to ask"), false);
user-cancel-as-rejected#Bridge.cpp#                m_bt->refuse(request, bt::kErrorCanceled, QStringLiteral("the user cancelled"));#                m_bt->refuse(request, bt::kErrorRejected, QStringLiteral("the user cancelled"));
decline-as-canceled#Bridge.cpp#                m_bt->refuse(request, bt::kErrorRejected, QStringLiteral("the user declined"));#                m_bt->refuse(request, bt::kErrorCanceled, QStringLiteral("the user declined"));
refusal-as-canceled#Bridge.cpp#            m_bt->refuse(request, bt::kErrorRejected, QStringLiteral("the shell could not take it"));#            m_bt->refuse(request, bt::kErrorCanceled, QStringLiteral("the shell could not take it"));
registered-for-any-shell (the kinds gate)#Bridge.cpp#                m_bt->setWanted(m_kinds.contains(QStringLiteral("bluetooth")));#                m_bt->setWanted(true);
passkey-not-zero-padded#BtPairing.cpp#        return QStringLiteral("%1").arg(passkey, kDigits, 10, QLatin1Char('0'));#        return QString::number(passkey);
path-not-checked#BtPairing.cpp#        if (!path)\n            return false;\n        constexpr char head[]#        if (path)\n            return true;\n        constexpr char head[]
passkey-answer-length-not-checked#BtPairing.cpp#        if (!text || length != static_cast<std::size_t>(kDigits))#        if (!text || length < 1 || length > static_cast<std::size_t>(kDigits))
pin-answer-not-checked#BtPairing.cpp#            if (!isAlnum(text[i]))\n                return false;#            ;
bluez-cancel-ignored#BtAgent.cpp#            endPending(bt::kErrorCanceled, QStringLiteral("bluetoothd cancelled it"));#            ;
cancel-ends-codes-shown (opus review of step 10, MINOR)#BtAgent.cpp#            endPending(bt::kErrorCanceled, QStringLiteral("bluetoothd cancelled it"));#            endAll(bt::kErrorCanceled, QStringLiteral("bluetoothd cancelled it"), true);
code-kept-when-disconnected (decision 10-16)#BtAgent.cpp#        const bool gone = device && g_variant_lookup(changed, "Connected", "b", &connected) && !connected;#        const bool gone = false;
code-kept-when-removed (decision 10-16)#BtAgent.cpp#                agent->endWith(r, nullptr, QStringLiteral("the device was removed"), true);#                ;
codes-not-capped (decision 10-16)#BtAgent.cpp#            if (!request->ended && bt::isDisplay(request->mode))\n                endWith(request, nullptr, why, true);#            if (false)\n                endWith(request, nullptr, why, true);
display-not-withdrawn-when-paired#BtAgent.cpp#        const bool done      = device && ((g_variant_lookup(changed, "Paired", "b", &paired) && paired) || (g_variant_lookup(changed, "Bonded", "b", &bonded) && bonded));#        const bool done      = false;
no-progress#BtAgent.cpp#                        m_sink->progressBt(r->id, digits); // may end it (the shell lost while sending)#                        ;
no-timeout#BtAgent.cpp#        request->timeout = g_timeout_add(static_cast<guint>(m_timeoutMs), onTimeout, request.get());#        request->timeout = 0;
not-reregistered-after-a-restart#BtAgent.cpp#        if (!owner.isEmpty() && m_wanted)\n            sendRegister();#        if (false)\n            sendRegister();
not-the-default-agent#BtAgent.cpp#                g_dbus_connection_call(agent->m_bus, bt::kBusName, bt::kAgentManagerPath, bt::kAgentManagerIface, "RequestDefaultAgent",#                g_dbus_connection_call(agent->m_bus, bt::kBusName, bt::kAgentManagerPath, bt::kAgentManagerIface, "NoSuchMethod",
display-cancel-does-not-stop-the-pairing#BtAgent.cpp#        g_dbus_connection_call(m_bus, request->owner.constData(), request->path.constData(), bt::kDeviceIface, "CancelPairing", nullptr, nullptr,#        g_dbus_connection_call(m_bus, request->owner.constData(), request->path.constData(), bt::kDeviceIface, "NoSuchMethod", nullptr, nullptr,
ok-for-a-code-shown#Bridge.cpp#        else if (display && answer.ok)\n            wrong = QStringLiteral("ok for a code shown");#        else if (false)\n            wrong = QStringLiteral("ok for a code shown");
bluetooth-places-not-kept (B-05)#Requests.cpp#        if (lane != Lane::Bluetooth)\n            kept += std::max(0, kReservedBluetooth - bt);#        if (false)\n            kept += std::max(0, kReservedBluetooth - bt);
waiting-takes-any-place (the applications' queue)#Requests.cpp#                if (!it->waiting || !fits(it->lane, it->caller))#                if (!it->waiting)
EOF_MUTANTS
fi
((rc == 0)) && echo "PASS: bluez_agent" || echo "FAIL: bluez_agent"
exit "$rc"
