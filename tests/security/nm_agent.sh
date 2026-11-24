#!/usr/bin/env bash
# grassfield-prompter's NetworkManager secret agent (ADR-0035 D-9, owner decision Q10; step 9c) on two private buses of the
# test's own: a "session" bus for gcr and a "system" bus with a fake NetworkManager (tests/fixtures/fake-networkmanager.py,
# owning org.freedesktop.NetworkManager and serving AgentManager), a fake attacker on that bus, a fake shell on the
# bridge's socket (tests/fixtures/prompter-shell.py) and, for the shared bound, a real libgcr client. Never the owner's
# buses, NetworkManager or secrets: every process runs under env -i with the test's scratch directories, the bridge as a
# development run, which refuses any bus that is not a private test bus. Test passwords only.
#  1 refusals at start: a development run whose DBUS_SYSTEM_BUS_ADDRESS is not a private test bus; --nm-timeout-ms outside
#    a development run
#  2 registration follows the shell: none without a shell, none for a shell that does not draw "nm", Register
#    ("org.grassfield.prompter") once it does
#  3 GetSecrets for WPA2 (psk), WPA3 (psk), WEP (the key of wep-tx-keyidx) and WPA2 Enterprise (the password; the
#    connection's username shown read-only): the shell gets kind nm with the SSID, the security and the username; its
#    answer reaches NetworkManager, which (the fake as the real one) keeps only secret properties: nothing is dropped;
#    an enterprise connection without a username is not asked (NoSecrets), an enterprise answer with a name is refused
#  4 the SSID is plain text (a line feed and a direction override flattened)
#  5 NoSecrets without a sheet: no interaction allowed (flags 0, USER_REQUESTED alone), VPN, an EAP method that takes a
#    certificate's password, a wired connection
#  6 the user's Cancel: UserCanceled; NetworkManager's CancelGetSecrets: the shell gets "cancel", the call AgentCanceled;
#    it withdraws only the request whose connection path and setting name both match (two others outstanding, one of the
#    same connection with another setting, one of the same setting on another connection)
#  7 a caller that is not the owner of org.freedesktop.NetworkManager gets PermissionDenied and the shell sees nothing;
#    its CancelGetSecrets cancels nothing
#  8 SaveSecrets is refused (Failed: nothing is stored here), DeleteSecrets succeeds
#  9 a wrong answer from the shell (a name for a WPA2 network, ok without a password, an empty password, a name for an
#    enterprise network) cancels the request: "cancel" to the shell, NoSecrets to NetworkManager; the shell's refusal
#    ("refused", its bound) is NoSecrets, never UserCanceled
# 10 the bound of 8 is shared with gcr's requests (B-05 and the applications' queue): six gcr prompts from three
#    connections, four shown and two waiting unseen; two nm requests still shown (NetworkManager keeps two places), a third
#    gets NoSecrets at once (six shown and BlueZ's two kept fill the 8); an nm request's freed place goes to the next nm
#    request, never to a waiting gcr request; the waiting ones shown on their turns, every request answered
# 11 the shell goes with a request outstanding: NoSecrets, and the agent unregisters; it comes back: Register again
# 12 NetworkManager restarts with a request outstanding: the shell gets "cancel"; the new NetworkManager gets Register
# 13 a request left unanswered past the answer's time (a bridge run with --nm-timeout-ms): withdrawn, NoSecrets
# 14 no test secret in the bridge's output
# Needs g++ with the Qt 6 Core and gcr-4 headers (or GRASSFIELD_PROMPTER: a built bridge), dbus-daemon, dbus-send, python3
# with PyGObject (Gio, and Gcr 4 for 10); SKIPs without them, when libdbus cannot reach the buses, and when this process has
# no cgroup of its own to stand for the shell's unit.
#
#   tests/security/nm_agent.sh              PASS / FAIL lines, exit 0 when all pass
#   tests/security/nm_agent.sh --mutants    also mutants of the agent's guards, which the checks must catch
set -uo pipefail
umask 077
root=$(git -C "$(dirname "$0")" rev-parse --show-toplevel)
mutants=0
case ${1:-} in
  "") ;;
  --mutants) mutants=1 ;;
  *) echo "usage: nm_agent.sh [--mutants]" >&2; exit 2 ;;
esac
for tool in dbus-daemon dbus-send python3; do
  command -v "$tool" >/dev/null || { echo "SKIP: nm_agent needs $tool"; exit 0; }
done
python3 -I -c 'import gi; gi.require_version("Gio", "2.0"); from gi.repository import Gio' 2>/dev/null || { echo "SKIP: nm_agent needs PyGObject"; exit 0; }
leaf=$(awk -F: '$1 == "0" {print $3}' /proc/self/cgroup | sed 's#.*/##')
[[ -n $leaf ]] || { echo "SKIP: nm_agent: this process sits at the root of its cgroup tree (no unit to stand for the shell's)"; exit 0; }

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
  tmp=$(mktemp -d "${GRASSFIELD_TEST_TMP:-${TMPDIR:-/tmp}}/nm-agent.XXXXXX")
  # Unix socket paths stay under 108 bytes: buses and the bridge's socket in a short directory of their own.
  d=$(mktemp -d /tmp/gfn.XXXXXX)
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
    wait_until 5 test -s "$d/$which.address" || { echo "SKIP: nm_agent: no private dbus-daemon (Unix sockets unavailable?)"; return 0; }
  done
  local bus sysbus
  bus=$(head -n 1 "$d/session.address")
  sysbus=$(head -n 1 "$d/system.address")
  dbus-send --bus="$sysbus" --print-reply --dest=org.freedesktop.DBus /org/freedesktop/DBus org.freedesktop.DBus.GetId >/dev/null 2>&1 \
    || { echo "SKIP: nm_agent: libdbus cannot reach the private bus"; return 0; }

  local run_env=(env -i PATH="$PATH" HOME="$d" XDG_RUNTIME_DIR="$d/run" DBUS_SESSION_BUS_ADDRESS="$bus" DBUS_SYSTEM_BUS_ADDRESS="$sysbus"
    GF_TEST_BUS=1 GF_TEST_BUS_DIR="$d" LC_ALL=C.UTF-8)
  local sock=$d/run/grassfield/prompter.sock
  local shell_py=$root/tests/fixtures/prompter-shell.py nm_py=$root/tests/fixtures/fake-networkmanager.py client_py=$root/tests/fixtures/prompter-client.py

  # --- 1 refusals at start ---------------------------------------------------------------------------------------------
  desc="a development run refuses a system bus that is not a private test bus (exit 3)"
  env -i PATH="$PATH" HOME="$d" XDG_RUNTIME_DIR="$d/run" DBUS_SESSION_BUS_ADDRESS="$bus" DBUS_SYSTEM_BUS_ADDRESS="unix:path=/run/dbus/system_bus_socket" \
    GF_TEST_BUS=1 GF_TEST_BUS_DIR="$d" GRASSFIELD_DEV=1 "$bridge" --socket "$sock" >"$tmp/r1.log" 2>&1
  check test $? -eq 3
  desc="--nm-timeout-ms is refused outside a development run (exit 3)"
  "${run_env[@]}" GRASSFIELD_SESSION=1 "$bridge" --socket "$sock" --nm-timeout-ms 1000 >"$tmp/r2.log" 2>&1
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
  nm_up() { # <tag> [--attacker]
    mkfifo "$d/$1.cmd"
    "${run_env[@]}" python3 -I "$nm_py" --log "$d/$1.nm" --commands "$d/$1.cmd" "${@:2}" </dev/null >"$d/$1.err" 2>&1 &
    nm_pid=$!
    pids+=("$nm_pid")
    wait_until 5 grep -q '^#ready' "$d/$1.nm" 2>/dev/null
  }
  say() { timeout 5 bash -c 'printf "%s\n" "$2" >"$1"' _ "$d/$1.cmd" "$2"; }
  has() { grep -q -- "$3" "$d/$1.$2" 2>/dev/null; }
  count() { grep -c -- "$3" "$d/$1.$2" 2>/dev/null; }
  last_prompt() { # <shell tag> <python expression on the last prompt line m>
    grep '"type":"prompt"' "$d/$1.shell" | tail -n 1 | python3 -I -c "import json,sys; m=json.loads(sys.stdin.read()); print($2)"
  }
  last_id() { last_prompt "$1" 'm["id"]'; }
  prompts() { count "$1" shell '"type":"prompt"'; }

  # --- 2 registration follows the shell --------------------------------------------------------------------------------
  nm_up nm
  start_bridge main --socket "$sock" --peer-unit "$leaf"
  local main_pid=$bridge_pid
  wait_until 5 test -S "$sock"
  wait_until 5 grep -q "NetworkManager secret agent ready on" "$d/main.log"
  local agent_name
  agent_name=$(sed -n 's/^grassfield-prompter: NetworkManager secret agent ready on \(:[0-9.]*\) .*/\1/p' "$d/main.log")
  sleep 0.3
  desc="without a shell the agent is not registered with NetworkManager"
  check bash -c '[[ -n $2 ]] && ! grep -q "^#register" "$1"' _ "$d/nm.nm" "$agent_name"
  shell_up old "$sock"
  say old "hello password confirm"
  sleep 0.5
  desc="a shell that does not draw \"nm\": still not registered"
  check bash -c '! grep -q "^#register" "$1"' _ "$d/nm.nm"
  say old close
  wait_until 5 grep -q "shell gone" "$d/main.log"
  shell_up s "$sock"
  say s "hello password confirm nm"
  desc="a shell that draws \"nm\" says hello: Register(\"org.grassfield.prompter\") from the bridge's own system bus connection"
  check wait_until 5 grep -qx "#register $agent_name org.grassfield.prompter" "$d/nm.nm"
  desc="...and the bridge's hello lists nm"
  check has s shell '"kinds":\["password","confirm","nm","kio","bluetooth"\]'

  # --- 3 the four forms ------------------------------------------------------------------------------------------------
  local n
  n=$(prompts s)
  say nm "get w1 802-11-wireless-security 0x1 ssid=Home"
  wait_until 10 bash -c '[[ $(grep -c "\"type\":\"prompt\"" "$1") -gt $2 ]]' _ "$d/s.shell" "$n"
  desc="WPA2: the shell gets kind nm, the SSID and the security, no requester object"
  check test "$(last_prompt s '"|".join((m["kind"], m["network"]["ssid"], m["network"]["security"], m["network"]["identity"], ",".join(sorted(m))))')" = "nm|Home|wpa||id,kind,network,type"
  say s "answer last ok correct horse 9"
  desc="...the password typed reaches NetworkManager as the setting's psk"
  check wait_until 10 grep -qx 'w1 secrets {"802-11-wireless-security": {"psk": "correct horse 9"}}' "$d/nm.nm"
  n=$(prompts s)
  say nm "get w2 802-11-wireless-security 0x3 keymgmt=sae ssid=Studio"
  wait_until 10 bash -c '[[ $(grep -c "\"type\":\"prompt\"" "$1") -gt $2 ]]' _ "$d/s.shell" "$n"
  desc="WPA3 (sae, REQUEST_NEW): security wpa3, the answer as psk"
  check test "$(last_prompt s 'm["network"]["security"]')" = wpa3
  say s "answer last ok sae-pass-1"
  desc="...the WPA3 password reaches NetworkManager as psk"
  check wait_until 10 grep -qx 'w2 secrets {"802-11-wireless-security": {"psk": "sae-pass-1"}}' "$d/nm.nm"
  n=$(prompts s)
  say nm "get w3 802-11-wireless-security 0x1 keymgmt=none wepidx=2 ssid=Old"
  wait_until 10 bash -c '[[ $(grep -c "\"type\":\"prompt\"" "$1") -gt $2 ]]' _ "$d/s.shell" "$n"
  desc="WEP: security wep, the answer as the key of wep-tx-keyidx (wep-key2)"
  check test "$(last_prompt s 'm["network"]["security"]')" = wep
  say s "answer last ok abcde"
  desc="...the WEP key reaches NetworkManager as wep-key2"
  check wait_until 10 grep -qx 'w3 secrets {"802-11-wireless-security": {"wep-key2": "abcde"}}' "$d/nm.nm"
  n=$(prompts s)
  say nm "get e1 802-1x 0x1 keymgmt=wpa-eap eap=peap identity=alice ssid=Office"
  wait_until 10 bash -c '[[ $(grep -c "\"type\":\"prompt\"" "$1") -gt $2 ]]' _ "$d/s.shell" "$n"
  desc="WPA2 Enterprise: security enterprise and the connection's username (shown read-only)"
  check test "$(last_prompt s '"|".join((m["network"]["security"], m["network"]["identity"]))')" = "enterprise|alice"
  say s "answer last ok ent-pass-2"
  desc="...the password reaches NetworkManager in 802-1x, the only property of the reply, nothing dropped"
  check wait_until 10 bash -c 'grep -qx "e1 secrets {\"802-1x\": {\"password\": \"ent-pass-2\"}}" "$1" && ! grep -q "^e1 dropped" "$1"' _ "$d/nm.nm"
  n=$(prompts s)
  say nm "get e2 802-1x 0x1 keymgmt=wpa-eap eap=peap ssid=Nameless"
  desc="an enterprise connection without a username is not asked: NoSecrets (a name typed would be dropped by NetworkManager)"
  check wait_until 10 grep -qx "e2 error org.freedesktop.NetworkManager.SecretAgent.NoSecrets" "$d/nm.nm"
  sleep 0.3
  desc="...and the shell was shown nothing"
  check test "$(prompts s)" = "$n"

  # --- 4 the SSID is plain text ----------------------------------------------------------------------------------------
  n=$(prompts s)
  say nm "get f1 802-11-wireless-security 0x1 ssidhex=436166c3a90ae280ae6576696c"
  wait_until 10 bash -c '[[ $(grep -c "\"type\":\"prompt\"" "$1") -gt $2 ]]' _ "$d/s.shell" "$n"
  desc="an SSID with a line feed and a direction override arrives flattened"
  check test "$(last_prompt s 'm["network"]["ssid"].encode().hex()')" = "436166c3a9206576696c"
  say s "answer last cancel"
  desc="the user's Cancel: UserCanceled"
  check wait_until 10 grep -qx "f1 error org.freedesktop.NetworkManager.SecretAgent.UserCanceled" "$d/nm.nm"

  # --- 5 NoSecrets without a sheet ----------------------------------------------------------------------------------------
  n=$(prompts s)
  say nm "get x1 802-11-wireless-security 0x0"
  say nm "get x2 802-11-wireless-security 0x4"
  say nm "get x3 vpn 0x1"
  say nm "get x4 802-1x 0x1 keymgmt=wpa-eap eap=tls identity=alice"
  say nm "get x5 802-11-wireless-security 0x1 type=802-3-ethernet"
  desc="no interaction allowed (0, USER_REQUESTED alone), VPN, EAP-TLS and a wired connection: NoSecrets for each"
  check wait_until 10 bash -c 'for t in x1 x2 x3 x4 x5; do grep -qx "$t error org.freedesktop.NetworkManager.SecretAgent.NoSecrets" "$1" || exit 1; done' _ "$d/nm.nm"
  sleep 0.3
  desc="...and the shell was shown none of them"
  check test "$(prompts s)" = "$n"
  desc="...the journal says why (no interaction, VPN)"
  check bash -c 'grep -q "answered NoSecrets: no interaction allowed" "$1" && grep -q "answered NoSecrets: VPN secrets are not asked" "$1"' _ "$d/main.log"

  # --- 6 NetworkManager cancels --------------------------------------------------------------------------------------------
  n=$(prompts s)
  say nm "get c1 802-11-wireless-security 0x1 ssid=Cancelled"
  wait_until 10 bash -c '[[ $(grep -c "\"type\":\"prompt\"" "$1") -gt $2 ]]' _ "$d/s.shell" "$n"
  local cid
  cid=$(last_id s)
  say nm "cancel c1"
  desc="CancelGetSecrets: the shell gets \"cancel $cid\" and the pending call AgentCanceled"
  check wait_until 10 bash -c 'grep -q "{\"id\":\"$2\",\"type\":\"cancel\"}" "$1" && grep -qx "c1 error org.freedesktop.NetworkManager.SecretAgent.AgentCanceled" "$3" && grep -qx "c1 cancel ok" "$3"' _ "$d/s.shell" "$cid" "$d/nm.nm"
  say s "answer $cid ok too-late-psk"
  desc="...and a late answer is ignored"
  check wait_until 5 grep -q "answer to $cid ignored: not outstanding" "$d/main.log"
  # Only the request whose connection path AND setting name match is withdrawn (the integrator's review of PR #96, m27).
  n=$(prompts s)
  say nm "get m1 802-11-wireless-security 0x1 path=40 ssid=MatchOne"
  wait_until 10 bash -c '[[ $(grep -c "\"type\":\"prompt\"" "$1") -gt $2 ]]' _ "$d/s.shell" "$n"
  local mid1 mid2 mid3
  mid1=$(last_id s)
  say nm "get m2 802-1x 0x1 path=40 keymgmt=wpa-eap eap=peap identity=alice ssid=MatchOne"
  wait_until 10 bash -c '[[ $(grep -c "\"type\":\"prompt\"" "$1") -gt $(($2 + 1)) ]]' _ "$d/s.shell" "$n"
  mid2=$(last_id s)
  say nm "get m3 802-11-wireless-security 0x1 path=41 ssid=MatchThree"
  wait_until 10 bash -c '[[ $(grep -c "\"type\":\"prompt\"" "$1") -gt $(($2 + 2)) ]]' _ "$d/s.shell" "$n"
  mid3=$(last_id s)
  say nm "cancel m1"
  wait_until 10 grep -qx "m1 cancel ok" "$d/nm.nm"
  sleep 0.5
  desc="CancelGetSecrets withdraws only the request whose connection path and setting both match [$mid1 $mid2 $mid3]"
  check bash -c 'grep -q "{\"id\":\"$2\",\"type\":\"cancel\"}" "$1" && grep -qx "m1 error org.freedesktop.NetworkManager.SecretAgent.AgentCanceled" "$3" && ! grep -q "{\"id\":\"$4\",\"type\":\"cancel\"}" "$1" && ! grep -q "{\"id\":\"$5\",\"type\":\"cancel\"}" "$1" && ! grep -q "^m2 error\|^m3 error" "$3"' _ "$d/s.shell" "$mid1" "$d/nm.nm" "$mid2" "$mid3"
  say s "answer $mid2 cancel"
  say s "answer $mid3 cancel"
  wait_until 10 bash -c 'grep -qx "m2 error org.freedesktop.NetworkManager.SecretAgent.UserCanceled" "$1" && grep -qx "m3 error org.freedesktop.NetworkManager.SecretAgent.UserCanceled" "$1"' _ "$d/nm.nm"

  # --- 7 a caller that is not NetworkManager ----------------------------------------------------------------------------
  nm_up att --attacker
  say att "target $agent_name"
  n=$(prompts s)
  say att "get a1 802-11-wireless-security 0x1 ssid=Phish"
  desc="a caller that does not own org.freedesktop.NetworkManager gets PermissionDenied"
  check wait_until 10 grep -qx "a1 error org.freedesktop.NetworkManager.SecretAgent.PermissionDenied" "$d/att.nm"
  sleep 0.3
  desc="...and the shell was shown nothing"
  check test "$(prompts s)" = "$n"
  desc="...the journal names the refusal"
  check grep -q "refused GetSecrets from :.*: not the owner of org.freedesktop.NetworkManager" "$d/main.log"
  say nm "get a2 802-11-wireless-security 0x1 ssid=Real"
  wait_until 10 bash -c '[[ $(grep -c "\"type\":\"prompt\"" "$1") -gt $2 ]]' _ "$d/s.shell" "$n"
  say att "get a2 802-11-wireless-security 0x1 ssid=Real"
  say att "cancel a2"
  desc="the attacker's CancelGetSecrets is refused and cancels nothing"
  check wait_until 10 grep -qx "a2 cancel error org.freedesktop.NetworkManager.SecretAgent.PermissionDenied" "$d/att.nm"
  say s "answer last ok real-psk-3"
  desc="...NetworkManager's request still gets its answer"
  check wait_until 10 grep -qx 'a2 secrets {"802-11-wireless-security": {"psk": "real-psk-3"}}' "$d/nm.nm"
  say att quit

  # --- 8 SaveSecrets, DeleteSecrets -------------------------------------------------------------------------------------
  say nm "save w1"
  say nm "delete w1"
  desc="SaveSecrets is refused (Failed: this agent stores nothing), DeleteSecrets succeeds"
  check wait_until 10 bash -c 'grep -qx "w1 save error org.freedesktop.NetworkManager.SecretAgent.Failed" "$1" && grep -qx "w1 delete ok" "$1"' _ "$d/nm.nm"

  # --- 9 wrong answers from the shell -------------------------------------------------------------------------------------
  local tag line
  for tag in b1 b2 b3 b4; do
    n=$(prompts s)
    if [[ $tag == b4 ]]; then
      say nm "get $tag 802-1x 0x1 keymgmt=wpa-eap eap=ttls identity=alice ssid=Wrong"
    else
      say nm "get $tag 802-11-wireless-security 0x1 ssid=Wrong"
    fi
    wait_until 10 bash -c '[[ $(grep -c "\"type\":\"prompt\"" "$1") -gt $2 ]]' _ "$d/s.shell" "$n"
    cid=$(last_id s)
    case $tag in
      b1) line="{\"type\":\"answer\",\"id\":\"$cid\",\"result\":\"ok\",\"password\":\"pw-b1\",\"identity\":\"eve\"}" ;;
      b2) line="{\"type\":\"answer\",\"id\":\"$cid\",\"result\":\"ok\"}" ;;
      b3) line="{\"type\":\"answer\",\"id\":\"$cid\",\"result\":\"ok\",\"password\":\"\"}" ;;
      b4) line="{\"type\":\"answer\",\"id\":\"$cid\",\"result\":\"ok\",\"password\":\"pw-b4\",\"identity\":\"mallory\"}" ;;
    esac
    say s "raw $line"
    wait_until 10 grep -qx "$tag error org.freedesktop.NetworkManager.SecretAgent.NoSecrets" "$d/nm.nm"
  done
  desc="a name for a WPA2 network, ok without a password, an empty password, a name for an enterprise network: each cancels its request (NoSecrets, \"cancel\")"
  check bash -c 'for t in b1 b2 b3 b4; do grep -qx "$t error org.freedesktop.NetworkManager.SecretAgent.NoSecrets" "$1" || exit 1; done; [[ $(grep -c "\"type\":\"cancel\"" "$2") -ge 5 ]]' _ "$d/nm.nm" "$d/s.shell"
  n=$(prompts s)
  say nm "get r0 802-11-wireless-security 0x1 ssid=Full"
  wait_until 10 bash -c '[[ $(grep -c "\"type\":\"prompt\"" "$1") -gt $2 ]]' _ "$d/s.shell" "$n"
  say s "raw {\"type\":\"answer\",\"id\":\"$(last_id s)\",\"result\":\"refused\"}"
  desc="the shell's refusal (\"refused\", its bound) is NoSecrets, never the user's UserCanceled"
  check wait_until 10 grep -qx "r0 error org.freedesktop.NetworkManager.SecretAgent.NoSecrets" "$d/nm.nm"

  # --- 10 the bound is shared with gcr ------------------------------------------------------------------------------------
  # B-05 (bridges/prompter/src/Requests.h) and its amendment (the applications' queue, owner decision 2026-11-22): of the
  # shell's 8 places NetworkManager and BlueZ keep two each; the applications' gcr prompts hold at most four (one connection
  # two), the others wait in the bridge, unseen and holding no place; NetworkManager's requests never wait.
  if python3 -I -c 'import gi; gi.require_version("Gcr", "4"); from gi.repository import Gcr' 2>/dev/null; then
    # ids_since <shell log line> <kind>: the ids of the prompts of that kind the shell got after that line, oldest first
    ids_since() {
      tail -n +"$(($1 + 1))" "$d/s.shell" | grep '"type":"prompt"' \
        | python3 -I -c 'import json,sys; [print(m["id"]) for m in map(json.loads, sys.stdin) if m["kind"] == sys.argv[1]]' "$2"
    }
    local from waits turns g nmids=()
    local canceled=org.freedesktop.NetworkManager.SecretAgent.UserCanceled
    from=$(wc -l <"$d/s.shell")
    n=$(prompts s)
    waits=$(count main log "waits for a place")
    turns=$(count main log "a place is free, its turn")
    # Three connections with two prompts each: whichever four are shown, each waiting one is held back by the applications'
    # share only (its connection shows fewer than two), so a place NetworkManager frees would fit it if the reserve were not
    # kept.
    for g in g1 g2 g3; do
      "${run_env[@]}" python3 -I "$client_py" many 2 >"$d/$g.out" 2>&1 &
      pids+=("$!")
    done
    desc="six gcr prompts from three connections: the shell gets the applications' four, the other two wait in the bridge"
    check wait_until 15 bash -c '[[ $(( $(grep -c "\"type\":\"prompt\"" "$1") - $2 )) == 4 && $(( $(grep -c "waits for a place" "$3") - $4 )) == 2 ]]' \
      _ "$d/s.shell" "$n" "$d/main.log" "$waits"
    say nm "get q1 802-11-wireless-security 0x1 ssid=Queue"
    say nm "get q2 802-11-wireless-security 0x1 ssid=Queue"
    desc="...two nm requests still reach the shell: NetworkManager keeps its two places, which the waiting gcr requests do not hold"
    check wait_until 10 bash -c '[[ $(( $(grep -c "\"type\":\"prompt\"" "$1") - $2 )) == 6 ]]' _ "$d/s.shell" "$n"
    say nm "get q3 802-11-wireless-security 0x1 ssid=Third"
    desc="...a third gets NoSecrets at once, never queued: six shown and BlueZ's two kept fill the shell's 8"
    check wait_until 10 grep -qx "q3 error org.freedesktop.NetworkManager.SecretAgent.NoSecrets" "$d/nm.nm"
    sleep 0.3
    desc="...the shell saw nothing of it, and no gcr request was answered or refused meanwhile"
    check bash -c '[[ $(( $(grep -c "\"type\":\"prompt\"" "$1") - $2 )) == 6 ]] && ! cat "$3" "$4" "$5" | grep -q -e cancelled -e password=' \
      _ "$d/s.shell" "$n" "$d/g1.out" "$d/g2.out" "$d/g3.out"
    mapfile -t nmids < <(ids_since "$from" nm)
    printf '%s\n' "${nmids[@]:0:1}" >"$d/answered"
    say s "answer ${nmids[0]:-none} cancel"
    wait_until 10 grep -qx "q1 error $canceled" "$d/nm.nm"
    sleep 1
    desc="an nm request cancelled by the user (q1, UserCanceled) leaves its place to NetworkManager: no waiting gcr request takes it"
    check bash -c 'grep -qx "q1 error $6" "$1" && [[ $(( $(grep -c "\"type\":\"prompt\"" "$2") - $3 )) == 6 && $(grep -c "a place is free, its turn" "$4") == "$5" ]]' \
      _ "$d/nm.nm" "$d/s.shell" "$n" "$d/main.log" "$turns" "$canceled"
    say nm "get q4 802-11-wireless-security 0x1 ssid=Queue"
    desc="...the next nm request (q4) gets it, shown at once"
    check wait_until 10 bash -c '[[ $(( $(grep -c "\"type\":\"prompt\"" "$1") - $2 )) == 7 ]]' _ "$d/s.shell" "$n"
    # Every prompt answered "cancel" as it reaches the shell: each gcr answer gives its place to a waiting gcr request.
    for _ in $(seq 1 30); do
      for cid in $(ids_since "$from" password) $(ids_since "$from" nm); do
        grep -qx "$cid" "$d/answered" && continue
        echo "$cid" >>"$d/answered"
        say s "answer $cid cancel"
      done
      [[ $(cat "$d/g1.out" "$d/g2.out" "$d/g3.out" | grep -c cancelled) -ge 6 ]] && break
      sleep 0.5
    done
    desc="...the two waiting gcr requests are shown on their turns, and every request gets its answer (gcr: six cancelled; nm: q2 and q4 UserCanceled)"
    check wait_until 10 bash -c '[[ $(cat "$1" "$2" "$3" | grep -c cancelled) == 6 && $(( $(grep -c "a place is free, its turn" "$4") - $5 )) == 2 ]] && for t in q2 q4; do grep -qx "$t error $7" "$6" || exit 1; done' \
      _ "$d/g1.out" "$d/g2.out" "$d/g3.out" "$d/main.log" "$turns" "$d/nm.nm" "$canceled"
  else
    echo "SKIP: nm_agent: the shared bound needs PyGObject with Gcr 4"
  fi

  # --- 11 the shell goes and comes back -------------------------------------------------------------------------------------
  n=$(prompts s)
  say nm "get g1 802-11-wireless-security 0x1 ssid=Gone"
  wait_until 10 bash -c '[[ $(grep -c "\"type\":\"prompt\"" "$1") -gt $2 ]]' _ "$d/s.shell" "$n"
  say s close
  desc="the shell goes with a request outstanding: NoSecrets"
  check wait_until 10 grep -qx "g1 error org.freedesktop.NetworkManager.SecretAgent.NoSecrets" "$d/nm.nm"
  desc="...and the agent unregisters from NetworkManager"
  check wait_until 10 grep -qx "#unregister $agent_name ok" "$d/nm.nm"
  say nm "target $agent_name"
  say nm "get g2 802-11-wireless-security 0x1 ssid=Nobody"
  desc="a call that still reaches the unregistered agent meanwhile: NoSecrets"
  check wait_until 10 grep -qx "g2 error org.freedesktop.NetworkManager.SecretAgent.NoSecrets" "$d/nm.nm"
  say nm "target -"
  shell_up s2 "$sock"
  say s2 "hello password confirm nm"
  desc="the shell comes back: Register again"
  check wait_until 10 bash -c '[[ $(grep -c "^#register $2 org.grassfield.prompter$" "$1") == 2 ]]' _ "$d/nm.nm" "$agent_name"

  # --- 12 NetworkManager restarts ---------------------------------------------------------------------------------------
  n=$(prompts s2)
  say nm "get r1 802-11-wireless-security 0x1 ssid=Restart"
  wait_until 10 bash -c '[[ $(grep -c "\"type\":\"prompt\"" "$1") -gt $2 ]]' _ "$d/s2.shell" "$n"
  cid=$(last_id s2)
  say nm quit
  desc="NetworkManager leaves with a request outstanding: the shell gets \"cancel $cid\""
  check wait_until 10 grep -q "{\"id\":\"$cid\",\"type\":\"cancel\"}" "$d/s2.shell"
  nm_up nm2
  desc="a new NetworkManager on the bus: the agent registers with it"
  check wait_until 10 grep -qx "#register $agent_name org.grassfield.prompter" "$d/nm2.nm"
  n=$(prompts s2)
  say nm2 "get r2 802-11-wireless-security 0x1 ssid=Again"
  wait_until 10 bash -c '[[ $(grep -c "\"type\":\"prompt\"" "$1") -gt $2 ]]' _ "$d/s2.shell" "$n"
  say s2 "answer last ok again-psk-4"
  desc="...and answers it"
  check wait_until 10 grep -qx 'r2 secrets {"802-11-wireless-security": {"psk": "again-psk-4"}}' "$d/nm2.nm"
  say s2 close
  wait_until 10 grep -q "#unregister $agent_name" "$d/nm2.nm"
  kill "$main_pid" 2>/dev/null

  # --- 13 the answer's time --------------------------------------------------------------------------------------------
  start_bridge short --socket "$d/run/grassfield/short.sock" --peer-unit "$leaf" --nm-timeout-ms 1500
  wait_until 5 test -S "$d/run/grassfield/short.sock"
  shell_up s3 "$d/run/grassfield/short.sock"
  say s3 "hello password confirm nm"
  wait_until 10 bash -c '[[ $(grep -c "^#register" "$1") -ge 2 ]]' _ "$d/nm2.nm"
  say nm2 "get t1 802-11-wireless-security 0x1 ssid=Slow"
  wait_until 10 grep -q '"kind":"nm"' "$d/s3.shell"
  cid=$(last_id s3)
  desc="a request left unanswered past the answer's time: withdrawn from the shell (\"cancel $cid\"), NoSecrets"
  check wait_until 10 bash -c 'grep -q "{\"id\":\"$2\",\"type\":\"cancel\"}" "$1" && grep -qx "t1 error org.freedesktop.NetworkManager.SecretAgent.NoSecrets" "$3"' _ "$d/s3.shell" "$cid" "$d/nm2.nm"

  # --- 14 nothing secret in the journal ---------------------------------------------------------------------------------
  desc="no test secret in the bridge's output"
  check bash -c '! grep -q -e "correct horse" -e sae-pass -e abcde -e ent-pass -e too-late -e real-psk -e pw-b1 -e pw-b4 -e again-psk "$1" "$2"' _ "$d/main.log" "$d/short.log"
  return $fail
}

bridge=${GRASSFIELD_PROMPTER:-}
tmpb=$(mktemp -d "${GRASSFIELD_TEST_TMP:-${TMPDIR:-/tmp}}/nm-agent-bin.XXXXXX")
trap 'cleanup; rm -rf "$tmpb"' EXIT
trap 'exit 130' INT
trap 'exit 143' TERM
if [[ -z $bridge ]]; then
  command -v g++ >/dev/null && pkg-config --exists Qt6Core gcr-4 libsecret-1 2>/dev/null || { echo "SKIP: nm_agent needs g++, Qt 6 Core, gcr-4 and libsecret"; exit 0; }
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
sender-not-checked#NmAgent.cpp#        if (owner.isEmpty() || sender != owner) {#        if (false) {
stays-registered-without-a-shell#NmAgent.cpp#        endAll(nm::kErrorNoSecrets, QStringLiteral("no shell to ask"), false);\n        sendUnregister();#        endAll(nm::kErrorNoSecrets, QStringLiteral("no shell to ask"), false);
vpn-asked#NmSecrets.cpp#        if (setting == "vpn")#        if (setting == "never")
asked-without-interaction#NmSecrets.cpp#        if (!interactionAllowed(flags))#        if (false)
cancel-ignored#NmAgent.cpp#                endWith(request, nm::kErrorAgentCanceled, QStringLiteral("NetworkManager cancelled it"), true);#                ;
cancel-by-path-only (m27, the integrator's review of PR 96)#NmAgent.cpp#            if (!request->ended && request->path == path && request->setting == setting) {#            if (!request->ended && request->path == path) {
cancel-by-setting-only#NmAgent.cpp#            if (!request->ended && request->path == path && request->setting == setting) {#            if (!request->ended && request->setting == setting) {
registered-for-any-shell#Bridge.cpp#                m_nm->setWanted(m_kinds.contains(QStringLiteral("nm")));#                m_nm->setWanted(true);
user-cancel-as-nosecrets#Bridge.cpp#                m_nm->refuse(request, nm::kErrorUserCanceled, QStringLiteral("the user cancelled"));#                m_nm->refuse(request, nm::kErrorNoSecrets, QStringLiteral("the user cancelled"));
name-accepted#Bridge.cpp#        else if (answer.hasIdentity)\n            wrong = QStringLiteral("a name where none is asked");\n        else if (!answer.ok && answer.hasPassword)#        else if (false)\n            wrong = QStringLiteral("a name where none is asked");\n        else if (!answer.ok && answer.hasPassword)
identity-in-the-reply (NetworkManager drops it)#NmSecrets.cpp#        g_variant_builder_init(&inner, G_VARIANT_TYPE("a{sv}"));#        g_variant_builder_init(&inner, G_VARIANT_TYPE("a{sv}"));\n        if (ask.security == Security::Enterprise)\n            g_variant_builder_add(&inner, "{sv}", "identity", g_variant_new_string(ask.identity.toUtf8().constData()));
asked-without-a-username#NmSecrets.cpp#            if (a.identity.isEmpty())#            if (false)
refusal-as-usercanceled#Bridge.cpp#                m_nm->refuse(request, nm::kErrorNoSecrets, QStringLiteral("the shell could not take it"));#                m_nm->refuse(request, nm::kErrorUserCanceled, QStringLiteral("the shell could not take it"));
no-timeout#NmAgent.cpp#        request->timeout = g_timeout_add(static_cast<guint>(m_timeoutMs), onTimeout, request.get());#        request->timeout = 0;
save-claims-success#NmAgent.cpp#            g_dbus_method_invocation_return_dbus_error(invocation, nm::kErrorFailed, "grassfield-prompter stores no secrets");#            g_dbus_method_invocation_return_value(invocation, nullptr);
not-reregistered-after-a-restart#NmAgent.cpp#        if (!owner.isEmpty() && m_wanted)\n            sendRegister();#        if (false)\n            sendRegister();
nm-places-not-kept (B-05)#Requests.cpp#        if (lane != Lane::Nm)\n            kept += std::max(0, kReservedNm - nm);#        if (false)\n            kept += std::max(0, kReservedNm - nm);
waiting-takes-any-place (the applications' queue)#Requests.cpp#                if (!it->waiting || !fits(it->lane, it->caller))#                if (!it->waiting)
EOF_MUTANTS
fi
((rc == 0)) && echo "PASS: nm_agent" || echo "FAIL: nm_agent"
exit "$rc"
