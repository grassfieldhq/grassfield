#!/usr/bin/env bash
# The shell's side of prompter/1 in a real Quickshell (ADR-0035 D-9, step 9b): shell/security/secret/PrompterClient.qml and
# SecretAgent.qml loaded by tests/security/secret_bridge.d/probe.qml (offscreen, next to links to the real shell modules),
# against a FAKE bridge (secret_bridge.d/fake_bridge.py, a Unix socket server of the test's own) and, when the tools are
# there, the REAL grassfield-prompter on a private test bus with a real libgcr client. Never the user's bus, socket or
# secrets: every socket and runtime directory is the test's own; test passwords only.
#   client   the client: its hello; one answer per request, only for its own open ids (an nm and a kio request's own fields,
#            steps 9c and 9e; a kio server that is not a host name closes the connection; a bluetooth request's code, and the
#            progress of a code shown, step 10); a withdrawal; a cancel for an
#            unknown id ignored; no late answer to a withdrawn request; a confirmation without a password; the check box's
#            state; a malformed line, an over-long line, a prompt before hello, another version and a duplicate id each
#            close the connection; the next attempt after 1 s, 2 s, 4 s, reset by a hello; no password in the shell's output
#   bound    SecretAgent (dev session, its test socket): the ninth request answered "cancelled" at once, the others wait
#   gate     a real session (GRASSFIELD_SESSION=1, a leaked GRASSFIELD_DEV=1 and a dev socket given): the agent connects
#            to $XDG_RUNTIME_DIR/grassfield/prompter.sock only and its dev hook answers "refused"; a dev session without a
#            test socket connects nowhere
#   e2e      the real bridge (a development run on a private bus, the probe's cgroup as --peer-unit) and libgcr's client
#            (tests/fixtures/prompter-client.py): a password typed in the shell reaches the gcr client through the sx-aes-1
#            exchange; a confirmation; a cancellation; step 9c: with a private "system" bus and a fake NetworkManager
#            (tests/fixtures/fake-networkmanager.py), the shell's real client registers the agent by its hello, and a WPA2
#            password, an enterprise password (nothing else: the fake keeps only secrets, as NetworkManager) and a
#            cancellation answered in the shell reach NetworkManager; step 9e: the shell's hello (kind kio) makes the bridge
#            hold org.kde.kpasswdserver6, and a KIO query (tests/fixtures/kpasswd-peer.py) answered in the shell gets its name
#            and password, a cancelled one nothing; step 10: with a fake bluetoothd (tests/fixtures/fake-bluez.py) on that
#            "system" bus, the shell's hello (kind bluetooth) registers the pairing agent as the default, and a passkey and a
#            confirmation answered in the shell reach bluetoothd (SKIP
#            without dbus-daemon, PyGObject with Gcr 4, a built bridge or g++ with Qt 6 Core and gcr-4, or a cgroup of this
#            process)
#
#   tests/security/secret_bridge.sh              PASS / FAIL lines, exit 0 when all pass
#   tests/security/secret_bridge.sh --mutants    also mutants of the client, which the fake-bridge scenarios must catch
set -uo pipefail
umask 077
root=$(git -C "$(dirname "$0")" rev-parse --show-toplevel)
cd "$root"
bd=$root/tests/security/secret_bridge.d
command -v qs >/dev/null || { echo "SKIP: secret_bridge needs qs (Quickshell)"; exit 0; }
command -v python3 >/dev/null || { echo "SKIP: secret_bridge needs python3"; exit 0; }
mutants=0
case ${1:-} in
  "") ;;
  --mutants) mutants=1 ;;
  *) echo "usage: secret_bridge.sh [--mutants]" >&2; exit 2 ;;
esac
unset QT_QPA_PLATFORMTHEME
mkdir -p "$root/.dev"
tmp=$(mktemp -d "$root/.dev/secret-bridge.XXXXXX")
# Unix socket paths stay under 108 bytes: sockets and runtime directories in a short directory of their own.
d=$(mktemp -d /tmp/gfs.XXXXXX) || { echo "ENVIRONMENT: no short scratch directory under /tmp (Unix socket paths stay under 108 bytes)"; exit 2; }
pids=()
bus_pid=""
stop_all() {
  local p
  for p in "${pids[@]}"; do kill "$p" 2>/dev/null; done
  [[ -n $bus_pid ]] && kill -TERM -- "-$bus_pid" 2>/dev/null
  wait 2>/dev/null
  rm -rf "$tmp" "$d"
}
trap stop_all EXIT
trap 'exit 130' INT
trap 'exit 143' TERM
fail=0
pass() { echo "PASS: secret bridge $*"; }
bad() { echo "FAIL: secret bridge $*"; fail=1; }
wait_until() { local n=$(($1 * 10)); shift; while ((n-- > 0)); do "$@" && return 0; sleep 0.1; done; return 1; }

ui/i18n/build-direct.sh >/dev/null 2>&1 || { echo "ENVIRONMENT: ui/i18n/build-direct.sh failed"; exit 2; }

# cfg <dir> <shell dir>: the probe as shell.qml next to links to every module of <shell dir> (the real shell, or a mutant).
# Offscreen Quickshell has no PanelWindow backend: security/secret holds links to the real files but SecretAgent.qml, whose
# window is an Item there (secret_sheets.d/make_harness.py --quickshell: nothing else of it changes).
cfg() {
  local dir=$1 src=$2 entry
  mkdir -p "$dir/security/secret"
  for entry in "$src"/*; do
    case $(basename "$entry") in
      shell.qml | security) ;;
      *) ln -s "$entry" "$dir/$(basename "$entry")" ;;
    esac
  done
  for entry in "$src"/security/* "$src"/security/qmldir; do
    [[ $(basename "$entry") == secret ]] || ln -sf "$entry" "$dir/security/$(basename "$entry")"
  done
  for entry in "$src"/security/secret/* "$src"/security/secret/qmldir; do
    [[ $(basename "$entry") == SecretAgent.qml ]] || ln -sf "$entry" "$dir/security/secret/$(basename "$entry")"
  done
  python3 -I "$root/tests/security/secret_sheets.d/make_harness.py" --quickshell "$src/security/secret/SecretAgent.qml" "$dir/security/secret/SecretAgent.qml" ||
    { echo "ENVIRONMENT: SecretAgent.qml changed shape"; exit 2; }
  cp "$bd/probe.qml" "$dir/shell.qml"
}
cfg "$tmp/cfg" "$root/shell"

# probe <out> <cfg> <env...>: the probe in the background (pid in probe_pid), offscreen, the test's own directories.
probe() {
  local out=$1 dir=$2
  shift 2
  mkdir -p "$d/home" "$d/cache"
  env -u WAYLAND_DISPLAY -u HYPRLAND_INSTANCE_SIGNATURE -u DISPLAY -u DBUS_SESSION_BUS_ADDRESS -u GRASSFIELD_DEV -u GRASSFIELD_SESSION \
    "$@" HOME="$d/home" XDG_CACHE_HOME="$d/cache" GRASSFIELD_STATE_HOME="$d/state" GRASSFIELD_CONFIG_HOME="$d/config" \
    QT_QPA_PLATFORM=offscreen QML_IMPORT_PATH="$root/ui:$root/.dev/build/qml" GRASSFIELD_LANG=en \
    timeout 90 qs -p "$dir" --no-color >"$out" 2>&1 </dev/null &
  probe_pid=$!
  pids+=("$probe_pid")
}
stop_probe() { kill "$probe_pid" 2>/dev/null; wait "$probe_pid" 2>/dev/null; }
# fake <scenario> <out> <socket> [<other>]: the fake bridge in the background (pid in fake_pid), ready when it listens.
fake() {
  local scenario=$1 out=$2
  shift 2
  python3 -I "$bd/fake_bridge.py" "$scenario" "$@" >"$out" 2>&1 &
  fake_pid=$!
  pids+=("$fake_pid")
  wait_until 5 test -e "$1.ready"
}
# report <fake out>: the fake bridge's PASS/FAIL lines.
report() {
  local line
  while IFS= read -r line; do
    case $line in
      PASS:*) pass "${line#PASS: }" ;;
      FAIL:*) bad "${line#FAIL: }" ;;
      *) [[ -n $line ]] && bad "fake bridge: $line" ;;
    esac
  done <"$1"
}

# run_client <shell dir>: the client scenario against the shell modules of <shell dir>; 0 when every check passed.
run_client() {
  local dir=$1 tag=$2
  mkdir -p "$d/$tag"
  fake client "$d/$tag/fake.out" "$d/$tag/c.sock"
  probe "$d/$tag/probe.out" "$dir" PROBE_MODE=client PROBE_SOCKET="$d/$tag/c.sock" XDG_RUNTIME_DIR="$d/$tag"
  wait "$fake_pid"
  local rc=$?
  stop_probe
  return $rc
}

# --- client --------------------------------------------------------------------------------------------------------------
run_client "$tmp/cfg" client
report "$d/client/fake.out"
out=$d/client/probe.out
grep -q "probe: withdrawn p2" "$out" && pass "client: a withdrawal reaches the agent" || bad "client: no withdrawal for p2"
grep -q "probe: answer p3 true second=false" "$out" && pass "client: a second answer to the same request is refused" || bad "client: answer twice: $(grep 'answer p3' "$out")"
grep -q "probe: late answer p4 false" "$out" && pass "client: an answer to a withdrawn request is refused" || bad "client: late answer: $(grep 'late answer' "$out")"
grep -q "probe: withdrawn p77" "$out" && bad "client: a cancel for an unknown id reached the agent" || pass "client: a cancel for an unknown id is ignored"
(($(grep -c "probe: lost" "$out") >= 5)) && pass "client: each closed connection drops its requests (lost)" || bad "client: lost $(grep -c 'probe: lost' "$out") times"
grep -q "grassfield-secret: closing the connection to grassfield-prompter" "$out" && pass "client: the journal says why a connection is closed" || bad "client: no closing line"
grep -q "pw-p" "$out" && bad "client: a password reached the shell's output" || pass "client: no password in the shell's output"
grep -qE "TypeError|ReferenceError|Binding loop|is not a function" "$out" && bad "client: QML errors: $(grep -E 'TypeError|ReferenceError' "$out" | head -3)" || pass "client: no QML runtime error"

# --- bound ----------------------------------------------------------------------------------------------------------------
mkdir -p "$d/bound"
fake bound "$d/bound/fake.out" "$d/bound/b.sock"
probe "$d/bound/probe.out" "$tmp/cfg" PROBE_MODE=agent PROBE_SOCKET="$d/bound/b.sock" GRASSFIELD_DEV=1 XDG_RUNTIME_DIR="$d/bound"
wait "$fake_pid"
stop_probe
report "$d/bound/fake.out"
grep -q "probe: devState ready owned shown=1 held=0 waiting=7 linger=0" "$d/bound/probe.out" \
  && pass "bound: one sheet shown, seven waiting (dev hook in a dev session)" || bad "bound: $(grep devState "$d/bound/probe.out" | head -5 | tr '\n' ' ')"

# --- gate -----------------------------------------------------------------------------------------------------------------
mkdir -p -m 700 "$d/gate/run/grassfield"
fake session-socket "$d/gate/fake.out" "$d/gate/run/grassfield/prompter.sock" "$d/gate/dev.sock"
probe "$d/gate/probe.out" "$tmp/cfg" PROBE_MODE=agent PROBE_SOCKET="$d/gate/dev.sock" GRASSFIELD_SESSION=1 GRASSFIELD_DEV=1 XDG_RUNTIME_DIR="$d/gate/run"
wait "$fake_pid"
stop_probe
report "$d/gate/fake.out"
[[ $(grep -o "probe: devState .*" "$d/gate/probe.out" | sort -u) == "probe: devState refused" ]] \
  && pass "gate: the dev hook answers \"refused\" in a real session" || bad "gate: $(grep devState "$d/gate/probe.out" | head -3 | tr '\n' ' ')"
mkdir -p -m 700 "$d/none/run/grassfield"
fake nothing "$d/none/fake.out" "$d/none/run/grassfield/prompter.sock"
probe "$d/none/probe.out" "$tmp/cfg" PROBE_MODE=agent GRASSFIELD_DEV=1 XDG_RUNTIME_DIR="$d/none/run"
wait "$fake_pid"
stop_probe
report "$d/none/fake.out"
grep -q "probe: devState off - shown=0" "$d/none/probe.out" && pass "gate: a dev session without a test socket stays off" || bad "gate: $(grep devState "$d/none/probe.out" | head -3)"

# --- e2e: the real bridge and a real gcr client ---------------------------------------------------------------------------
e2e() {
  local tool
  for tool in dbus-daemon dbus-send; do
    command -v "$tool" >/dev/null || { echo "SKIP: secret bridge e2e needs $tool"; return 0; }
  done
  python3 -I -c 'import gi; gi.require_version("Gcr", "4"); from gi.repository import Gcr' 2>/dev/null || { echo "SKIP: secret bridge e2e needs PyGObject with Gcr 4"; return 0; }
  local bridge=${GRASSFIELD_PROMPTER:-}
  if [[ -z $bridge ]]; then
    command -v g++ >/dev/null && pkg-config --exists Qt6Core gcr-4 libsecret-1 2>/dev/null || { echo "SKIP: secret bridge e2e needs g++, Qt 6 Core, gcr-4 and libsecret"; return 0; }
    bridges/prompter/build-direct.sh --out "$tmp/bin" >"$tmp/build.log" 2>&1 || { cat "$tmp/build.log"; bad "e2e: the bridge builds"; return 0; }
    bridge=$tmp/bin/grassfield-prompter
  fi
  local leaf
  leaf=$(awk -F: '$1 == "0" {print $3}' /proc/self/cgroup | sed 's#.*/##')
  [[ -n $leaf ]] || { echo "SKIP: secret bridge e2e: this process has no cgroup of its own to stand for the shell's unit"; return 0; }
  local e=$d/e
  mkdir -p "$e/services" "$e/run"
  printf '%s\n' '<!DOCTYPE busconfig PUBLIC "-//freedesktop//DTD D-Bus Bus Configuration 1.0//EN" "http://www.freedesktop.org/standards/dbus/1.0/busconfig.dtd">' \
    '<busconfig>' '  <type>session</type>' "  <listen>unix:path=$e/bus.sock</listen>" '  <auth>EXTERNAL</auth>' \
    "  <servicedir>$e/services</servicedir>" '  <policy context="default">' '    <allow send_destination="*" eavesdrop="true"/>' \
    '    <allow eavesdrop="true"/>' '    <allow own="*"/>' '  </policy>' '</busconfig>' >"$e/bus.conf"
  sed -e 's#<type>session</type>#<type>system</type>#' -e "s#$e/bus.sock#$e/sys.sock#" "$e/bus.conf" >"$e/sys.conf"
  setsid env -i PATH="$PATH" HOME="$e" XDG_RUNTIME_DIR="$e/run" dbus-daemon --config-file="$e/bus.conf" --nofork --print-address=1 \
    >"$e/bus.address" 2>"$e/bus.log" </dev/null &
  bus_pid=$!
  setsid env -i PATH="$PATH" HOME="$e" XDG_RUNTIME_DIR="$e/run" dbus-daemon --config-file="$e/sys.conf" --nofork --print-address=1 \
    >"$e/sys.address" 2>"$e/sys.log" </dev/null &
  sys_pid=$!
  pids+=("$sys_pid")
  wait_until 5 test -s "$e/bus.address" || { echo "SKIP: secret bridge e2e: no private dbus-daemon"; return 0; }
  wait_until 5 test -s "$e/sys.address" || { echo "SKIP: secret bridge e2e: no second private dbus-daemon"; return 0; }
  local bus sysbus
  bus=$(head -n 1 "$e/bus.address")
  sysbus=$(head -n 1 "$e/sys.address")
  local run_env=(env -i PATH="$PATH" HOME="$e" XDG_RUNTIME_DIR="$e/run" DBUS_SESSION_BUS_ADDRESS="$bus" DBUS_SYSTEM_BUS_ADDRESS="$sysbus" GF_TEST_BUS=1 GF_TEST_BUS_DIR="$e" LC_ALL=C.UTF-8)
  mkfifo "$e/nm.cmd"
  "${run_env[@]}" python3 -I "$root/tests/fixtures/fake-networkmanager.py" --log "$e/nm.log" --commands "$e/nm.cmd" </dev/null >"$e/nm.err" 2>&1 &
  pids+=("$!")
  wait_until 5 grep -q '^#owned' "$e/nm.log" 2>/dev/null || { bad "e2e: the fake NetworkManager owns its name: $(cat "$e/nm.err")"; return 0; }
  mkfifo "$e/bz.cmd"
  "${run_env[@]}" python3 -I "$root/tests/fixtures/fake-bluez.py" --log "$e/bz.log" --commands "$e/bz.cmd" </dev/null >"$e/bz.err" 2>&1 &
  pids+=("$!")
  wait_until 5 grep -q '^#owned' "$e/bz.log" 2>/dev/null || { bad "e2e: the fake bluetoothd owns its name: $(cat "$e/bz.err")"; return 0; }
  local sock=$e/run/grassfield/prompter.sock
  "${run_env[@]}" GRASSFIELD_DEV=1 "$bridge" --socket "$sock" --peer-unit "$leaf" >"$e/bridge.log" 2>&1 &
  pids+=("$!")
  wait_until 5 test -S "$sock" || { bad "e2e: the bridge listens"; return 0; }
  probe "$e/probe.out" "$tmp/cfg" PROBE_MODE=client PROBE_SOCKET="$sock" XDG_RUNTIME_DIR="$d/home"
  wait_until 15 grep -q '"state":"owned"\|org.gnome.keyring.SystemPrompter owned' "$e/probe.out" \
    || { bad "e2e: the shell connects and the bridge owns the name: $(tail -3 "$e/bridge.log" | tr '\n' ' ')"; stop_probe; return 0; }
  pass "e2e: the real bridge accepts the shell's hello and owns org.gnome.keyring.SystemPrompter"
  local c=$root/tests/fixtures/prompter-client.py
  "${run_env[@]}" timeout 20 python3 -I "$c" password --title answer-ok --message "A test" >"$e/c1.out" 2>&1
  grep -q '^password=pw-p1$' "$e/c1.out" && pass "e2e: the password the shell answers reaches libgcr's client through the exchange" \
    || bad "e2e: password: $(cat "$e/c1.out" | tr '\n' ' ')"
  "${run_env[@]}" timeout 20 python3 -I "$c" confirm --title answer-ok >"$e/c2.out" 2>&1
  grep -q '^continue$' "$e/c2.out" && pass "e2e: a confirmation answered ok: the client continues" || bad "e2e: confirm: $(cat "$e/c2.out" | tr '\n' ' ')"
  "${run_env[@]}" timeout 20 python3 -I "$c" password --title answer-cancel >"$e/c3.out" 2>&1
  grep -q '^cancelled$' "$e/c3.out" && pass "e2e: a cancellation: the client gets no password" || bad "e2e: cancel: $(cat "$e/c3.out" | tr '\n' ' ')"
  grep -q "request p1 answered: ok" "$e/bridge.log" && grep -q 'shell probe says hello (draws: password,confirm,nm,kio,bluetooth)' "$e/bridge.log" \
    && pass "e2e: the bridge's journal: the shell's hello and its answers" || bad "e2e: bridge log: $(grep -E 'hello|answered' "$e/bridge.log" | head -3 | tr '\n' ' ')"
  # Step 9c: NetworkManager's secrets through the shell's real client.
  wait_until 10 grep -q '^#register .* org.grassfield.prompter$' "$e/nm.log" && pass "e2e: the shell's hello (kinds password, confirm, nm) registers the NetworkManager agent" \
    || bad "e2e: no Register: $(cat "$e/nm.log" | tr '\n' ' ')"
  local say_nm='printf "%s\n" "$2" >"$1"'
  timeout 5 bash -c "$say_nm" _ "$e/nm.cmd" "get n1 802-11-wireless-security 0x1 ssid=answer-ok"
  wait_until 15 grep -qE '^n1 secrets \{"802-11-wireless-security": \{"psk": "pw-p[0-9]+"\}\}$' "$e/nm.log" \
    && pass "e2e: a WPA2 password answered in the shell reaches NetworkManager" || bad "e2e: WPA2: $(grep '^n1' "$e/nm.log")"
  timeout 5 bash -c "$say_nm" _ "$e/nm.cmd" "get n2 802-1x 0x1 keymgmt=wpa-eap eap=peap identity=alice ssid=answer-ok"
  wait_until 15 grep -qE '^n2 secrets \{"802-1x": \{"password": "pw-p[0-9]+"\}\}$' "$e/nm.log" && ! grep -q '^n2 dropped' "$e/nm.log" \
    && pass "e2e: an enterprise password answered in the shell reaches NetworkManager, nothing in the reply dropped" || bad "e2e: enterprise: $(grep '^n2' "$e/nm.log")"
  timeout 5 bash -c "$say_nm" _ "$e/nm.cmd" "get n3 802-11-wireless-security 0x1 ssid=answer-cancel"
  wait_until 15 grep -qx 'n3 error org.freedesktop.NetworkManager.SecretAgent.UserCanceled' "$e/nm.log" \
    && pass "e2e: a cancellation in the shell: UserCanceled" || bad "e2e: cancel: $(grep '^n3' "$e/nm.log")"
  # Step 9e: KIO's network passwords through the shell's real client.
  wait_until 10 grep -q "org.kde.kpasswdserver6 owned" "$e/bridge.log" && pass "e2e: the shell's hello (kind kio) makes the bridge hold org.kde.kpasswdserver6" \
    || bad "e2e: org.kde.kpasswdserver6 not held: $(grep kpasswdserver6 "$e/bridge.log" | tr '\n' ' ')"
  mkfifo "$e/st.cmd"
  "${run_env[@]}" python3 -I "$root/tests/fixtures/kpasswd-peer.py" stranger --log "$e/st.log" --commands "$e/st.cmd" </dev/null >"$e/st.err" 2>&1 &
  pids+=("$!")
  wait_until 5 grep -q '^#ready' "$e/st.log" 2>/dev/null
  timeout 5 bash -c "$say_nm" _ "$e/st.cmd" "query sftp://answer-ok.example/"
  wait_until 15 grep -qE '^result query [0-9]+ modified=1 user=user-p[0-9]+ password=pw-p[0-9]+$' "$e/st.log" \
    && grep -qE 'prompted p[0-9]+ kio unidentified answer-ok.example edit off unknown' "$e/probe.out" \
    && pass "e2e: a KIO query answered in the shell gets the name and the password typed (the real client reads the bridge's kio line)" \
    || bad "e2e: kio: $(cat "$e/st.log" | tr '\n' ' ') $(grep 'kio' "$e/probe.out" | tr '\n' ' ')"
  timeout 5 bash -c "$say_nm" _ "$e/st.cmd" "query sftp://answer-cancel.example/"
  wait_until 15 grep -qE '^result query [0-9]+ modified=0 user=- password=-$' "$e/st.log" \
    && pass "e2e: a KIO query cancelled in the shell gets nothing" || bad "e2e: kio cancel: $(cat "$e/st.log" | tr '\n' ' ')"
  # Step 10: BlueZ's pairing steps through the shell's real client.
  wait_until 10 grep -q '^#default .* /org/grassfield/prompter/BluetoothAgent$' "$e/bz.log" \
    && pass "e2e: the shell's hello (kind bluetooth) registers the pairing agent as bluetoothd's default" || bad "e2e: no default agent: $(cat "$e/bz.log" | tr '\n' ' ')"
  timeout 5 bash -c "$say_nm" _ "$e/bz.cmd" "device AA_BB_CC_DD_EE_01 alias=answer-ok icon=input-keyboard"
  timeout 5 bash -c "$say_nm" _ "$e/bz.cmd" "passkey b1 AA_BB_CC_DD_EE_01"
  wait_until 15 grep -qx 'b1 ok 123456' "$e/bz.log" && grep -qE 'prompted p[0-9]+ bluetooth passkey' "$e/probe.out" \
    && pass "e2e: a passkey answered in the shell reaches bluetoothd (the real client reads the bridge's bluetooth line)" || bad "e2e: passkey: $(grep '^b1' "$e/bz.log") $(grep bluetooth "$e/probe.out" | tr '\n' ' ')"
  timeout 5 bash -c "$say_nm" _ "$e/bz.cmd" "confirm b2 AA_BB_CC_DD_EE_01 42"
  wait_until 15 grep -qx 'b2 ok' "$e/bz.log" && pass "e2e: a confirmation answered in the shell: Connect reaches bluetoothd" || bad "e2e: confirm: $(grep '^b2' "$e/bz.log")"
  grep -q "pw-p\|123456" "$e/bridge.log" "$e/probe.out" && bad "e2e: a password or a code in an output" || pass "e2e: no password or code in the bridge's or the shell's output"
  stop_probe
  wait_until 10 grep -q '^#unregister .* ok$' "$e/nm.log" && pass "e2e: the shell gone, the agent unregisters" || bad "e2e: no Unregister: $(tail -3 "$e/nm.log" | tr '\n' ' ')"
  wait_until 10 grep -q '^#unregister .* /org/grassfield/prompter/BluetoothAgent$' "$e/bz.log" && pass "e2e: the shell gone, the pairing agent unregisters" \
    || bad "e2e: no UnregisterAgent: $(tail -3 "$e/bz.log" | tr '\n' ' ')"
}
e2e

if ((mutants)); then
  # Mutants of the client: each must make the client scenario fail. Triples '#'-separated: file under shell/, text, replacement.
  # Not listed: answer() without its check of the open ids, which Prompter.answerLine repeats (no line for an id it does
  # not hold), so nothing changes on the socket.
  while IFS= read -r line; do
    [[ -n $line ]] || continue
    IFS='#' read -r -a f <<<"$line"
    name=${f[0]}
    m=$tmp/mut
    rm -rf "$m" "$tmp/mcfg"
    mkdir -p "$m"
    cp -a "$root/shell/." "$m/"
    if ! python3 -I - "$m/${f[1]}" "${f[2]}" "${f[3]}" <<'PY'; then echo "MUTANT $name: NOT APPLIED"; fail=1; continue; fi
import sys
p, a, b = sys.argv[1], sys.argv[2].replace("\\n", "\n"), sys.argv[3].replace("\\n", "\n")
s = open(p).read()
if s.count(a) != 1:
    sys.exit(3)
open(p, "w").write(s.replace(a, b))
PY
    cfg "$tmp/mcfg" "$m"
    if run_client "$tmp/mcfg" "mut-$RANDOM" >/dev/null 2>&1; then echo "MUTANT $name: NOT CAUGHT"; fail=1; else echo "MUTANT $name: CAUGHT"; fi
  done <<'EOF_MUTANTS'
answers-twice#security/secret/PrompterClient.qml#        const line = Prompter.answerLine(priv.open[id], ok, password, choice, identity);\n        if (line === "")\n            return false;\n        root.forget(id);#        const line = Prompter.answerLine(priv.open[id], ok, password, choice, identity);\n        if (line === "")\n            return false;
withdrawn-stays-open#security/secret/PrompterClient.qml#            root.forget(m.id);#            ;
lenient-parser#security/secret/PrompterClient.qml#        if (!parsed.ok) {\n            root.fail(parsed.reason);\n            return;\n        }#        if (!parsed.ok)\n            return;
duplicate-id-accepted#security/secret/PrompterClient.qml#                root.fail("request " + m.id + " sent twice");#                ;
no-back-off#security/secret/PrompterClient.qml#            retry.interval = Prompter.retryDelay(priv.failures);#            retry.interval = 100;
no-hello#security/secret/PrompterClient.qml#socket.write(Prompter.helloLine(root.shellVersion)#socket.write(""
strict-parser-off#security/secret/Prompter.js#    if (!exactKeys(m, ["type", "id", "kind", "requester", "texts", "choice", "passwordNew", "strength"]))#    if (false)
nm-name-sent (opus review of step 9c, MAJOR)#security/secret/Prompter.js#        const nmLine = JSON.stringify(m);#        if (typeof identity === "string")\n            m.identity = identity;\n        const nmLine = JSON.stringify(m);
nm-not-drawn#security/secret/Prompter.js#var KINDS = ["password", "confirm", "nm", "kio", "bluetooth"];#var KINDS = ["password", "confirm", "kio", "bluetooth"];
kio-not-drawn#security/secret/Prompter.js#var KINDS = ["password", "confirm", "nm", "kio", "bluetooth"];#var KINDS = ["password", "confirm", "nm", "bluetooth"];
bluetooth-not-drawn (step 10)#security/secret/Prompter.js#var KINDS = ["password", "confirm", "nm", "kio", "bluetooth"];#var KINDS = ["password", "confirm", "nm", "kio"];
progress-ignored (step 10)#security/secret/PrompterClient.qml#            root.progressed(m.id, m.entered);#            ;
progress-for-any-request (step 10)#security/secret/PrompterClient.qml#            if (priv.open[m.id].mode !== "display-passkey") {#            if (false) {
bluetooth-display-answered-ok (step 10)#security/secret/Prompter.js#            if (mode === "display-pin" || mode === "display-passkey")\n                return "";#            if (false)\n                return "";
kio-server-lenient#security/secret/Prompter.js#    if (typeof m.server !== "string" || m.server.length > CAPS.server || !SERVER_PATTERN.test(m.server))#    if (typeof m.server !== "string" || m.server.length > CAPS.server)
kio-name-where-none-asked#security/secret/Prompter.js#            if (login.nameMode === "edit") {#            if (true) {
nm-network-lenient#security/secret/Prompter.js#    if (n.security !== "enterprise" && n.identity !== "")#    if (false)
EOF_MUTANTS
fi

((fail == 0)) && echo "PASS: secret_bridge" || echo "FAIL: secret_bridge"
exit "$fail"
