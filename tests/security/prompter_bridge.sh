#!/usr/bin/env bash
# grassfield-prompter (ADR-0035 D-9, step 9a) on a private bus of the test's own, with a fake shell on its socket
# (tests/fixtures/prompter-shell.py), real gcr clients (libgcr-4 through PyGObject, tests/fixtures/prompter-client.py, and
# Arch's pinentry-gnome3, a libgcr-3 client, when installed) and fake name holders. Never the owner's bus, files or secrets:
# every process runs under env -i with the test's scratch directories, the bridge as a development run, which refuses any
# bus that is not a private test bus. Test passwords only.
#  1 refusals at start: outside a session, a development run on a bus that is not a private test bus or without --socket,
#    a socket directory that is a symlink, a --peer-unit that is not a service name in a session
#  2 the socket's directory is 0700 and the socket 0600; the bridge is not dumpable; the name is not taken without a shell,
#    and a request that reaches the bridge (by its unique name) with no shell connected at all is answered "cancelled" at once
#  3 a socket peer outside the expected unit is refused (the fake shell runs outside --peer-unit grassfield-shell.service, and
#    outside the built-in default, grassfield-security.service, ADR-0041 S3, when no --peer-unit is given),
#    and ten more at once leave one line in the bridge's output;
#    a second shell connection is refused while one is connected; a hello of another version closes the connection
#  4 a connected shell that has not said hello: the bridge does not take the name yet, and a request that reaches the
#    bridge meanwhile (by its unique name) is answered "cancelled" at once (no shell ready); the shell's hello: the bridge
#    owns org.gnome.keyring.SystemPrompter
#  5 a password from a real gcr client through the sx-aes-1 exchange: the prompt names the caller from its pidfd (the client's
#    interpreter, a root-owned program without its own desktop entry: "unidentified" with its path), its text flattened, the
#    check box, the answer's choice back to the client; a confirmation, accepted and refused
#    a caller that names another connection ("grassfield-caller") in its own properties is still shown as itself
#  6 pinentry-gnome3 (GnuPG's prompt) is shown as "gnupg", on someone's behalf, and gets its PIN (SKIP when absent)
#  7 a caller that stops prompting (StopPrompting) or leaves the bus: "cancel <id>" reaches the shell, the caller gets no
#    password
#  8 nine requests at once (from two connections: one connection holds at most eight prompts, 11b): the shell gets
#    eight, the ninth is answered "cancelled" at once; the eight are answered
#  9 protocol errors: an answer to an id that is not outstanding is ignored (the request still waits for its real answer);
#    "ok" without a password cancels that request; an over-long line closes the connection, cancels the outstanding
#    request and releases the name; an answer before hello closes the connection
# 10 the shell disconnects with a request outstanding: the caller gets "cancelled", the name is released; it reconnects:
#    the name is taken again
# 11 an attacker that asks to replace the name's owner while the bridge holds it is only queued and receives no call at all and the client gets its password
#    from the shell; when the shell goes, the name passes to the next in line (gcr's design: the known limitation)
# 11b one connection holds at most 8 open prompts (with callback objects, so gcr keeps them all): its 9th BeginPrompting
#    gets LimitsExceeded, another connection is still served; a caller without callback objects is never held back
#    (gcr drops each prompt whose PromptReady fails, and so does the count); interface-less StopPrompting calls free
#    nothing (GDBus answers them UnknownMethod and gcr never sees them), so seventy rounds of them leave the pool for
#    others (counter-review MINOR-B); a PerformPrompt of the wrong shape gets InvalidArgs from the bridge at once
# 11c a long-lived client (one connection, as gnome-keyring-daemon) whose prompt is in flight each time the shell goes,
#    eight times, is served again after (counter-review MINOR-A: gcr's clients forget such prompts without stopping them)
# 11d the shell's write side fails (EPIPE, its reading side shut down, no end ever read) while gcr ends the prompts of a
#    caller that left the bus with eight open, one of them performed: the bridge stays up and the departure closes no
#    prompt from inside gcr's own clean-up (opus final check of step 9a, MAJOR: a use-after-free in gcr before the fix)
# 12 queued behind a holder that owns the name first (the stock gcr-prompter for 10 s after its last prompt): "queued",
#    then "owned" once the holder exits
# 13 no test password in the bridge's journal output
#
#   tests/security/prompter_bridge.sh              PASS / FAIL lines, exit 0 when all pass
#   tests/security/prompter_bridge.sh --mutants    also mutants of the bridge's guards (the integrator's review of PR #95: the
#                                                  name only after the hello, the line wiping, the answer without a shell, the
#                                                  pidfd's re-check, the known callers' namespaces: every known caller exempt,
#                                                  or the disk helper not, decision 9-26 amended), each built and run against
#                                                  the unit tests and this scenario; every one must be caught
# Needs g++ with the Qt 6 Core and gcr-4 headers (or GRASSFIELD_PROMPTER: a built bridge), dbus-daemon, dbus-send, python3
# with PyGObject and the Gcr 4 introspection data; SKIPs without them, when libdbus cannot reach the bus, and when this
# process has no cgroup of its own to stand for the shell's unit.
set -uo pipefail
umask 077
root=$(git -C "$(dirname "$0")" rev-parse --show-toplevel)
mutants=0
case ${1:-} in
  "") ;;
  --mutants) mutants=1 ;;
  *) echo "usage: prompter_bridge.sh [--mutants]" >&2; exit 2 ;;
esac
tmp=$(mktemp -d "${GRASSFIELD_TEST_TMP:-${TMPDIR:-/tmp}}/prompter-bridge.XXXXXX")
# Unix socket paths stay under 108 bytes: the bus and the bridge's socket live in a short directory of their own.
d=$(mktemp -d /tmp/gfp.XXXXXX) || { echo "ENVIRONMENT: no short scratch directory under /tmp (Unix socket paths stay under 108 bytes)"; exit 2; }
bus_pid=""
pids=()
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
check() { if "$@"; then echo "PASS: $desc"; else echo "FAIL: $desc"; fail=1; fi; }
wait_until() { local n=$(($1 * 10)); shift; while ((n-- > 0)); do "$@" && return 0; sleep 0.1; done; return 1; }

for tool in dbus-daemon dbus-send python3; do
  command -v "$tool" >/dev/null || { echo "SKIP: prompter_bridge needs $tool"; exit 0; }
done
python3 -I -c 'import gi; gi.require_version("Gcr", "4"); from gi.repository import Gcr' 2>/dev/null \
  || { echo "SKIP: prompter_bridge needs PyGObject with Gcr 4"; exit 0; }
bridge=${GRASSFIELD_PROMPTER:-}
if [[ -z $bridge ]]; then
  command -v g++ >/dev/null && pkg-config --exists Qt6Core gcr-4 libsecret-1 2>/dev/null || { echo "SKIP: prompter_bridge needs g++, Qt 6 Core, gcr-4 and libsecret"; exit 0; }
  "$root/bridges/prompter/build-direct.sh" --out "$tmp/bin" >"$tmp/build.log" 2>&1 || { cat "$tmp/build.log"; echo "FAIL: the bridge builds"; exit 1; }
  bridge=$tmp/bin/grassfield-prompter
fi
shell_py=$root/tests/fixtures/prompter-shell.py
client_py=$root/tests/fixtures/prompter-client.py
leaf=$(awk -F: '$1 == "0" {print $3}' /proc/self/cgroup | sed 's#.*/##')
[[ -n $leaf ]] || { echo "SKIP: prompter_bridge: this process sits at the root of its cgroup tree (no unit to stand for the shell's)"; exit 0; }

# --- the private bus ---------------------------------------------------------------------------------------------------
mkdir -p "$d/services" "$d/run"
printf '%s\n' '<!DOCTYPE busconfig PUBLIC "-//freedesktop//DTD D-Bus Bus Configuration 1.0//EN" "http://www.freedesktop.org/standards/dbus/1.0/busconfig.dtd">' \
  '<busconfig>' '  <type>session</type>' "  <listen>unix:path=$d/bus.sock</listen>" '  <auth>EXTERNAL</auth>' \
  "  <servicedir>$d/services</servicedir>" '  <policy context="default">' '    <allow send_destination="*" eavesdrop="true"/>' \
  '    <allow eavesdrop="true"/>' '    <allow own="*"/>' '  </policy>' '</busconfig>' >"$d/bus.conf"
setsid env -i PATH="$PATH" HOME="$d" XDG_RUNTIME_DIR="$d/run" dbus-daemon --config-file="$d/bus.conf" --nofork --print-address=1 \
  >"$d/bus.address" 2>"$d/bus.log" </dev/null &
bus_pid=$!
wait_until 5 test -s "$d/bus.address" || { echo "SKIP: prompter_bridge: no private dbus-daemon (Unix sockets unavailable?)"; exit 0; }
bus=$(head -n 1 "$d/bus.address")
dbus-send --bus="$bus" --print-reply --dest=org.freedesktop.DBus /org/freedesktop/DBus org.freedesktop.DBus.GetId >/dev/null 2>&1 \
  || { echo "SKIP: prompter_bridge: libdbus cannot reach the private bus"; exit 0; }

run_env=(env -i PATH="$PATH" HOME="$d" XDG_RUNTIME_DIR="$d/run" DBUS_SESSION_BUS_ADDRESS="$bus" GF_TEST_BUS=1 GF_TEST_BUS_DIR="$d" LC_ALL=C.UTF-8)
name=org.gnome.keyring.SystemPrompter
owner_of() { dbus-send --bus="$bus" --print-reply --dest=org.freedesktop.DBus /org/freedesktop/DBus org.freedesktop.DBus.GetNameOwner "string:$1" 2>/dev/null | awk -F'"' '/string/ {print $2}'; }
pid_of_owner() {
  local o
  o=$(owner_of "$name")
  [[ -n $o ]] || return 0
  dbus-send --bus="$bus" --print-reply --dest=org.freedesktop.DBus /org/freedesktop/DBus org.freedesktop.DBus.GetConnectionUnixProcessID "string:$o" 2>/dev/null | awk '/uint32/ {print $2}'
}
owned_by() { [[ $(pid_of_owner) == "$1" ]]; }
unowned() { [[ -z $(owner_of "$name") ]]; }

# start_bridge <tag> [args...]: a development run on the private bus; sets bridge_pid
start_bridge() {
  local tag=$1
  shift
  "${run_env[@]}" GRASSFIELD_DEV=1 "$bridge" "$@" >"$d/$tag.log" 2>&1 &
  bridge_pid=$!
  pids+=("$bridge_pid")
}
# shell_up <tag> <socket>: the fake shell, connected; say <tag> <command> drives it, lines <tag> <pattern> counts what it got
shell_up() {
  mkfifo "$d/$1.cmd"
  python3 -I "$shell_py" --socket "$2" --log "$d/$1.shell" --commands "$d/$1.cmd" </dev/null >/dev/null 2>&1 &
  pids+=("$!")
  wait_until 5 grep -q '^#connect' "$d/$1.shell" 2>/dev/null
}
say() { timeout 5 bash -c 'printf "%s\n" "$2" >"$1"' _ "$d/$1.cmd" "$2"; }
lines() { grep -c -- "$2" "$d/$1.shell" 2>/dev/null; }
has_line() { grep -q -- "$2" "$d/$1.shell" 2>/dev/null; }
# client <tag> <mode> [args...]: a gcr client in the background; its output in $d/<tag>.out
client() {
  local tag=$1
  shift
  "${run_env[@]}" python3 -I "$client_py" "$@" >"$d/$tag.out" 2>&1 &
  pids+=("$!")
  client_pid=$!
}
out_has() { grep -q -- "$2" "$d/$1.out" 2>/dev/null; }
prompt_ids() { grep '"type":"prompt"' "$d/$1.shell" | python3 -I -c 'import json,sys; [print(json.loads(l)["id"]) for l in sys.stdin]'; }
field() { # field <tag> <n> <python expression on the n-th prompt line m>
  grep '"type":"prompt"' "$d/$1.shell" | sed -n "${2}p" | python3 -I -c "import json,sys; m=json.loads(sys.stdin.read()); r=m['requester']; print($3)"
}
sock=$d/run/grassfield/prompter.sock

# --- 1 refusals at start -----------------------------------------------------------------------------------------------
desc="refused outside a Grassfield session and outside a development run (exit 3)"
"${run_env[@]}" "$bridge" --socket "$sock" >"$tmp/r1.log" 2>&1
check test $? -eq 3
desc="a development run refuses a bus that is not a private test bus, and one without --socket (exit 3)"
env -i PATH="$PATH" HOME="$d" XDG_RUNTIME_DIR="$d/run" DBUS_SESSION_BUS_ADDRESS="$bus" GF_TEST_BUS=1 GF_TEST_BUS_DIR=/elsewhere GRASSFIELD_DEV=1 \
  "$bridge" --socket "$sock" >"$tmp/r2.log" 2>&1
r2=$?
"${run_env[@]}" GRASSFIELD_DEV=1 "$bridge" >"$tmp/r3.log" 2>&1
check test "$r2/$?" = 3/3
desc="a socket directory that is a symlink is refused (exit 2)"
mkdir -p "$d/real" && ln -s "$d/real" "$d/run/linked"
"${run_env[@]}" GRASSFIELD_DEV=1 "$bridge" --socket "$d/run/linked/p.sock" >"$tmp/r4.log" 2>&1
check bash -c '[[ $1 == 2 ]] && grep -q "symlinks are refused" "$2"' _ $? "$tmp/r4.log"
desc="in a session, --peer-unit must be a service name (exit 3)"
"${run_env[@]}" GRASSFIELD_SESSION=1 "$bridge" --socket "$sock" --peer-unit "app-foot.scope" >"$tmp/r5.log" 2>&1
check test $? -eq 3

# --- 2 the socket, the process, no name without a shell -----------------------------------------------------------------
start_bridge main --socket "$sock" --peer-unit "$leaf"
main_pid=$bridge_pid
wait_until 5 test -S "$sock"
desc="the socket's directory is 0700 and the socket 0600, both the user's"
check bash -c '[[ $(stat -c %a "$1") == 700 && $(stat -c %a "$2") == 600 && $(stat -c %u "$2") == $(id -u) ]]' _ "$d/run/grassfield" "$sock"
desc="the bridge is not dumpable (its /proc entries belong to root)"
check bash -c '[[ $(stat -c %u /proc/$1/environ) == 0 ]]' _ "$main_pid"
sleep 0.3
desc="without a shell the bridge does not take $name"
check unowned
bridge_name=$(sed -n 's/^grassfield-prompter: .* prompter\/1 on \(:[0-9.]*\) (development.*/\1/p' "$d/main.log")
client noshell password --title "No shell" --prompter "$bridge_name"
desc="a request that reaches the bridge (by its unique name) with no shell connected is answered \"cancelled\" at once"
check wait_until 10 bash -c 'grep -q "^cancelled" "$1" && grep -q "a password request answered \"cancelled\": no shell" "$2"' _ "$d/noshell.out" "$d/main.log"

# --- 3 who may connect ---------------------------------------------------------------------------------------------------
# The built-in default (ADR-0041 S3; the opus review of S3, NIT): with no --peer-unit the bridge expects the security process's
# unit, where the secret sheets run, and refuses any other peer.
start_bridge default --socket "$d/run/grassfield/default.sock"
default_pid=$bridge_pid
wait_until 5 test -S "$d/run/grassfield/default.sock"
shell_up outdefault "$d/run/grassfield/default.sock"
say outdefault hello
desc="with no --peer-unit the bridge expects grassfield-security.service (its built-in default) and refuses a peer outside it"
check wait_until 5 bash -c 'grep -q "listening on .* for grassfield-security.service " "$1" && grep -q "\"code\":\"refused\"" "$2" && grep -q "peer is not in grassfield-security.service" "$1"' _ "$d/default.log" "$d/outdefault.shell"
kill "$default_pid" 2>/dev/null
wait "$default_pid" 2>/dev/null
start_bridge strict --socket "$d/run/grassfield/strict.sock" --peer-unit grassfield-shell.service
strict_pid=$bridge_pid
wait_until 5 test -S "$d/run/grassfield/strict.sock"
shell_up outsider "$d/run/grassfield/strict.sock"
say outsider hello
desc="a peer outside the expected unit (--peer-unit grassfield-shell.service) is refused and closed, and the name stays free"
check wait_until 5 bash -c 'grep -q "\"code\":\"refused\"" "$1" && grep -q "^#closed" "$1"' _ "$d/outsider.shell"
wait_until 3 grep -q "refused a connection" "$d/strict.log"
desc="...the bridge's output says why, and the name stays free"
check bash -c 'grep -q "refused a connection from pid .*: peer is not in grassfield-shell.service" "$1" && [[ -z $(dbus-send --bus="$2" --print-reply --dest=org.freedesktop.DBus /org/freedesktop/DBus org.freedesktop.DBus.GetNameOwner string:org.gnome.keyring.SystemPrompter 2>/dev/null) ]]' _ "$d/strict.log" "$bus"
python3 -I -c '
import socket, sys
for _ in range(10):
    s = socket.socket(socket.AF_UNIX)
    s.connect(sys.argv[1])
    s.recv(200)
    s.close()' "$d/run/grassfield/strict.sock"
desc="ten more refused connections at once: still one line in the bridge's output (refusals are logged once per 10 s)"
check bash -c '[[ $(grep -c "refused a connection" "$1") == 1 ]]' _ "$d/strict.log"
desc="...and when the window ends without another refusal, one line counts the others (counter-review NIT)"
check wait_until 15 grep -q "^grassfield-prompter: 10 more connection(s) refused in the last 10 s, not logged one by one$" "$d/strict.log"
kill "$strict_pid" 2>/dev/null

shell_up badver "$sock"
say badver 'raw {"v":"prompter/9","type":"hello","kinds":["password"]}'
desc="a hello of another protocol version closes the connection"
check wait_until 5 bash -c 'grep -q "\"code\":\"version\"" "$1" && grep -q "^#closed" "$1"' _ "$d/badver.shell"
shell_up early "$sock"
say early 'answer p1 ok early-secret'
desc="an answer before hello closes the connection"
check wait_until 5 grep -q "^#closed" "$d/early.shell"

# --- 4 hello: the name -------------------------------------------------------------------------------------------------
shell_up s "$sock"
sleep 0.5
desc="a connected shell that has not said hello: the bridge does not take $name yet"
check unowned
client silent password --title "Before hello" --prompter "$bridge_name"
desc="...and a request that reaches it meanwhile is answered \"cancelled\" at once (no shell ready)"
check wait_until 10 grep -q "^cancelled" "$d/silent.out"
say s hello
desc="after the shell's hello the bridge owns $name (and tells the shell)"
check wait_until 5 owned_by "$main_pid"
desc="...and the shell is told: name owned"
check wait_until 3 has_line s '"state":"owned"'
shell_up second "$sock"
desc="a second shell connection is refused while one is connected"
check wait_until 5 bash -c 'grep -q "\"code\":\"busy\"" "$1" && grep -q "^#closed" "$1"' _ "$d/second.shell"

# --- 5 password and confirmation through a real gcr client -----------------------------------------------------------------
py=$(readlink -f "$(command -v python3)")
rlo=$(printf '\xe2\x80\xae') # U+202E, a direction override
client c1 password --title "Unlock the login keyring" --message "An application wants access
to the keyring${rlo}gnp.exe" --choice "Remember this password"
wait_until 10 has_line s '"type":"prompt"'
desc="the prompt reaches the shell with an id, kind password, and the caller resolved from its pidfd (unidentified, its path)"
check test "$(field s 1 '"|".join(str(x) for x in (m["id"], m["kind"], r["role"], r["identified"], r["onBehalf"], r["path"]))')" = "p1|password|unidentified|False|False|$py"
desc="the caller's text arrives flattened (no line break, no direction override), with the check box"
check test "$(field s 1 '"|".join((m["texts"]["title"], m["texts"]["message"], m["choice"]["label"], str(m["choice"]["chosen"])))')" \
  = "Unlock the login keyring|An application wants access to the keyringgnp.exe|Remember this password|False"
say s 'answer last ok-choice correct horse 1'
desc="the password the shell sends reaches the gcr client through the exchange, with the choice"
check wait_until 10 bash -c 'grep -qx "password=correct horse 1" "$1" && grep -qx "choice=1" "$1"' _ "$d/c1.out"
client c2 confirm --title "Store passwords unencrypted?"
wait_until 10 bash -c '[[ $(grep -c "\"type\":\"prompt\"" "$1") -ge 2 ]]' _ "$d/s.shell"
say s 'confirm last ok'
desc="a confirmation accepted by the shell: the client gets \"continue\""
check wait_until 10 grep -qx continue "$d/c2.out"
client c3 confirm --title "Again?"
wait_until 10 bash -c '[[ $(grep -c "\"type\":\"prompt\"" "$1") -ge 3 ]]' _ "$d/s.shell"
say s 'confirm last cancel'
desc="a confirmation refused by the shell: the client gets \"cancel\""
check wait_until 10 grep -qx cancel "$d/c3.out"

# A caller cannot choose who it is: it names the bridge's own connection, the sheet still shows the caller's executable.
before=$(lines s '"type":"prompt"')
client cf forge --caller "$bridge_name"
wait_until 10 bash -c '[[ $(grep -c "\"type\":\"prompt\"" "$1") -gt $2 ]]' _ "$d/s.shell" "$before"
desc="a caller that puts \"grassfield-caller\": <the bridge's own name $bridge_name> in its properties is shown as itself"
check test "$(field s "$((before + 1))" '"|".join((m["texts"]["title"], r["role"], r["path"]))')" = "Forged|unidentified|$py"
say s 'answer last cancel'
desc="...and gets the shell's answer through gcr's protocol (cancelled: \"no\")"
check wait_until 10 grep -qx "reply=no" "$d/cf.out"

# --- 6 pinentry-gnome3 -------------------------------------------------------------------------------------------------
if [[ -x /usr/bin/pinentry-gnome3 && $(stat -c %u /usr/bin/pinentry-gnome3) == 0 ]]; then
  before=$(lines s '"type":"prompt"')
  printf 'SETDESC Please enter the passphrase to unlock the OpenPGP secret key\nGETPIN\nBYE\n' \
    | "${run_env[@]}" WAYLAND_DISPLAY=wayland-test timeout 20 /usr/bin/pinentry-gnome3 >"$d/pin.out" 2>"$d/pin.err" &
  pids+=("$!")
  wait_until 10 bash -c '[[ $(grep -c "\"type\":\"prompt\"" "$1") -gt $2 ]]' _ "$d/s.shell" "$before"
  n=$((before + 1))
  desc="pinentry-gnome3 (a libgcr-3 client) is shown as GnuPG, asking on someone's behalf"
  check test "$(field s "$n" '"|".join(str(x) for x in (r["role"], r["identified"], r["onBehalf"], r["path"]))')" = "gnupg|True|True|/usr/bin/pinentry-gnome3"
  say s 'answer last ok pin-0451'
  desc="pinentry-gnome3 gets the PIN the shell sends"
  check wait_until 10 grep -qx "D pin-0451" "$d/pin.out"
else
  echo "SKIP: pinentry-gnome3 is not installed as root's /usr/bin/pinentry-gnome3"
fi

# --- 7 the caller withdraws ---------------------------------------------------------------------------------------------
before=$(lines s '"type":"cancel"')
client c4 password --title "Withdrawn" --close-when "$d/close-c4"
wait_until 10 bash -c 'grep "\"type\":\"prompt\"" "$1" | tail -n 1 | grep -q Withdrawn' _ "$d/s.shell"
id4=$(prompt_ids s | tail -n 1)
touch "$d/close-c4"
desc="StopPrompting from the caller: \"cancel $id4\" reaches the shell and the caller gets no password"
check wait_until 10 bash -c 'grep -q "{\"id\":\"$2\",\"type\":\"cancel\"}" "$1" && ! grep -q "^password=" "$3"' _ "$d/s.shell" "$id4" "$d/c4.out"
client c5 password --title "Vanishing"
wait_until 10 bash -c 'grep "\"type\":\"prompt\"" "$1" | tail -n 1 | grep -q Vanishing' _ "$d/s.shell"
id5=$(prompt_ids s | tail -n 1)
kill -KILL "$client_pid"
wait "$client_pid" 2>/dev/null
desc="a caller that leaves the bus: \"cancel $id5\" reaches the shell"
check wait_until 10 grep -q "{\"id\":\"$id5\",\"type\":\"cancel\"}" "$d/s.shell"
say s "answer $id5 ok too-late-secret"
desc="an answer to the withdrawn request is ignored"
check wait_until 5 grep -q "answer to $id5 ignored: not outstanding" "$d/main.log"

# --- 8 nine at once ------------------------------------------------------------------------------------------------------
before=$(lines s '"type":"prompt"')
client c6 many 5
client c6b many 4
desc="nine requests at once from two callers: the ninth is answered \"cancelled\" at once"
check wait_until 15 bash -c '[[ $(cat "$1" "$2" | grep -c "cancelled") == 1 ]]' _ "$d/c6.out" "$d/c6b.out"
desc="...and the shell got eight of them"
check wait_until 5 bash -c '[[ $(( $(grep -c "\"type\":\"prompt\"" "$1") - $2 )) == 8 ]]' _ "$d/s.shell" "$before"
for id in $(prompt_ids s | tail -n 8); do say s "answer $id ok batch-$id"; done
desc="...and the eight answers reach their eight callers"
check wait_until 15 bash -c '[[ $(cat "$1" "$2" | grep -c "password=batch-p") == 8 ]]' _ "$d/c6.out" "$d/c6b.out"

# --- 9 protocol errors ----------------------------------------------------------------------------------------------------
client c7 password --title "Errors"
wait_until 10 bash -c 'grep "\"type\":\"prompt\"" "$1" | tail -n 1 | grep -q Errors' _ "$d/s.shell"
id7=$(prompt_ids s | tail -n 1)
say s 'answer p999999 ok invented-secret'
desc="an answer to an id that is not outstanding is ignored, and the real request keeps waiting"
check wait_until 5 bash -c 'grep -q "answer to p999999 ignored" "$1" && ! grep -q "^password=\|cancelled" "$2"' _ "$d/main.log" "$d/c7.out"
say s "raw {\"type\":\"answer\",\"id\":\"$id7\",\"result\":\"ok\"}"
desc="\"ok\" without a password cancels that request: \"cancel $id7\" to the shell, \"cancelled\" to the caller"
check wait_until 10 bash -c 'grep -q "{\"id\":\"$2\",\"type\":\"cancel\"}" "$1" && grep -q "^cancelled" "$3"' _ "$d/s.shell" "$id7" "$d/c7.out"
client c8 password --title "Overlong"
wait_until 10 bash -c 'grep "\"type\":\"prompt\"" "$1" | tail -n 1 | grep -q Overlong' _ "$d/s.shell"
say s 'long 20000'
desc="an over-long line closes the connection and cancels the outstanding request"
check wait_until 10 bash -c 'grep -q "^#closed" "$1" && grep -q "^cancelled" "$2"' _ "$d/s.shell" "$d/c8.out"
desc="...and the name is released"
check wait_until 5 unowned

# --- 10 disconnect and reconnect -------------------------------------------------------------------------------------------
shell_up s2 "$sock"
say s2 hello
wait_until 5 owned_by "$main_pid"
client c9 password --title "Disconnect"
wait_until 10 has_line s2 Disconnect
say s2 close
desc="the shell disconnects with a request outstanding: the caller gets \"cancelled\""
check wait_until 10 bash -c 'grep -q "^cancelled" "$1"' _ "$d/c9.out"
desc="...and the name is released"
check wait_until 5 unowned
shell_up s3 "$sock"
say s3 hello
desc="the shell reconnects: the name is taken again"
check wait_until 5 owned_by "$main_pid"

# --- 11 an attacker queued behind the bridge -----------------------------------------------------------------------------
client attacker holder --log "$d/attacker.calls" --flags 2
attacker_pid=$client_pid
desc="an attacker asking to replace the owner of the name (REPLACE_EXISTING) while the bridge holds it is only queued (RequestName answers 2)"
check wait_until 5 grep -qx "reply=2" "$d/attacker.out"
client c10 password --title "Queued attacker"
wait_until 10 has_line s3 'Queued attacker'
say s3 'answer last ok attacker-never-sees-this'
desc="the client gets its password from the shell and the attacker received no call at all"
check wait_until 10 bash -c 'grep -qx "password=attacker-never-sees-this" "$1" && [[ ! -s $2 ]]' _ "$d/c10.out" "$d/attacker.calls"
say s3 close
desc="when the shell goes, the bridge lets the name go to the next in line (gcr's design: the documented limitation)"
check wait_until 5 owned_by "$attacker_pid"
kill "$attacker_pid" 2>/dev/null
wait_until 5 unowned

# --- 11b one connection's share of open prompts; a malformed PerformPrompt ---------------------------------------------
shell_up s5 "$sock"
say s5 hello
wait_until 5 owned_by "$main_pid"
client hog begins 9 --objects
desc="one connection holds at most 8 open prompts that gcr keeps: its ninth BeginPrompting is answered LimitsExceeded"
check wait_until 10 bash -c '[[ $(grep -c "^begin [0-7] ok$" "$1") == 8 ]] && grep -qx "begin 8 error org.freedesktop.DBus.Error.LimitsExceeded" "$1"' _ "$d/hog.out"
client lossy begins 9 --pause 0.3
desc="a caller without callback objects is not held back: gcr drops each prompt whose PromptReady fails, and so does the count"
check wait_until 15 bash -c '[[ $(grep -c "^begin [0-8] ok$" "$1") == 9 ]]' _ "$d/lossy.out"
client nif noiface 70
nif_pid=$client_pid
desc="seventy rounds of BeginPrompting and an interface-less StopPrompting: eight held, the rest refused, every stop UnknownMethod"
check wait_until 60 bash -c 'grep -qx "begin ok: 8" "$1" && grep -qx "begin refused: 62" "$1" && grep -qx "stop org.freedesktop.DBus.Error.UnknownMethod: 70" "$1"' _ "$d/nif.out"
client c11 password --title "After the hog"
desc="...another connection is still served meanwhile"
check wait_until 10 has_line s5 'After the hog'
say s5 'answer last ok after-the-hog'
check wait_until 10 grep -qx "password=after-the-hog" "$d/c11.out"
kill "$nif_pid" 2>/dev/null
client bad badperform
desc="a PerformPrompt of the wrong shape gets InvalidArgs from the bridge at once, and never reaches gcr"
check wait_until 10 grep -q "^error org.freedesktop.DBus.Error.InvalidArgs: PerformPrompt takes (o callback" "$d/bad.out"
say s5 close
wait_until 5 unowned

# --- 11c a long-lived client across eight shell departures ------------------------------------------------------------
mkdir -p "$d/ll"
n_shell=0
next_shell() { n_shell=$((n_shell + 1)); shell_up "ll$n_shell" "$sock" && say "ll$n_shell" hello && wait_until 5 owned_by "$main_pid"; }
next_shell
client ll longlived "$d/ll" 11
for i in 0 1 2 3 4 5 6 7 8 9 10; do
  touch "$d/ll/go-$i"
  wait_until 10 has_line "ll$n_shell" "Long-lived $i" || break
  if ((i < 8)); then
    say "ll$n_shell" close # the shell goes with the prompt in flight
    wait_until 10 grep -qx "$i cancelled" "$d/ll.out"
    next_shell
  else
    say "ll$n_shell" "answer last ok long-lived-$i"
    wait_until 10 grep -qx "$i password=long-lived-$i" "$d/ll.out"
  fi
done
desc="a long-lived client whose prompt was in flight at each of eight shell departures is served again after them"
check bash -c '[[ $(grep -c "^[0-7] cancelled$" "$1") == 8 ]] && grep -qx "8 password=long-lived-8" "$1" && grep -qx "10 password=long-lived-10" "$1" && ! grep -q "open error" "$1"' _ "$d/ll.out"
desc="...because at each departure gcr ended its open prompts (none left to fill the pool of 64)"
check bash -c '[[ $(grep -c "open gcr prompt(s) closed: their callers saw the name go (0 still open)$" "$1") -ge 8 ]] && ! grep -q "still open)$" <(grep -v "(0 still open)$" "$1")' _ "$d/main.log"
say "ll$n_shell" close
wait_until 5 unowned

# --- 11d a write error inside gcr's clean-up --------------------------------------------------------------------------
for which in 0 7; do
  shell_up half$which "$sock"
  say half$which hello
  wait_until 5 owned_by "$main_pid"
  client vanish$which vanish 8 "$which" "$d/half$which.go"
  wait_until 10 has_line half$which "Vanishing with 8 open"
  say half$which halfclose
  errors_before=$(grep -c "shell gone: write error" "$d/main.log")
  closed_before=$(grep -c " (0 still open)$" "$d/main.log")
  wait_until 5 grep -q "^#halfclosed" "$d/half$which.shell" && touch "$d/half$which.go"
  desc="a caller with eight prompts open (prompt $which performed) leaves while the half-closed shell's writes fail: the bridge stays up"
  check wait_until 10 bash -c 'grep -qx vanishing "$1" && [[ $(grep -c "shell gone: write error" "$2") -gt $4 ]] && sleep 1 && kill -0 "$3"' _ "$d/vanish$which.out" "$d/main.log" "$main_pid" "$errors_before"
  desc="...and the departure's prompts are ended after gcr's own clean-up, none left open"
  check wait_until 10 bash -c '[[ $(grep -c " (0 still open)$" "$1") -gt $2 ]]' _ "$d/main.log" "$closed_before"
  wait_until 5 unowned
done

# --- 12 queued behind a holder ---------------------------------------------------------------------------------------------
client stock holder --log "$d/stock.calls"
stock_pid=$client_pid
wait_until 5 grep -qx "reply=1" "$d/stock.out"
shell_up s4 "$sock"
say s4 hello
desc="a holder that owned the name first keeps it: the bridge is queued behind it and says so"
check wait_until 5 bash -c 'grep -q "\"state\":\"queued\"" "$1" && grep -q "queued behind it" "$2"' _ "$d/s4.shell" "$d/main.log"
kill "$stock_pid"
desc="once the holder exits, the bridge owns the name"
check wait_until 5 bash -c 'grep -q "\"state\":\"owned\"" "$1"' _ "$d/s4.shell"
desc="...and the bus says the bridge owns it"
check wait_until 5 owned_by "$main_pid"

# --- 13 nothing secret in the journal ----------------------------------------------------------------------------------------
desc="no test password in the bridge's output"
check bash -c '! grep -q -e "correct horse" -e pin-0451 -e batch-p -e invented-secret -e attacker-never -e too-late -e early-secret -e after-the-hog -e long-lived- "$1"' _ "$d/main.log"

kill "$main_pid" 2>/dev/null
desc="the bridge stops on SIGTERM and removes its socket"
check wait_until 5 bash -c '[[ ! -e $1 ]]' _ "$sock"

if ((mutants)); then
  # Each mutant removes one guard (file under bridges/prompter/src, text that occurs once, replacement; \n a newline): its
  # bridge and unit tests are built from a copy, then the unit tests and this scenario run; one of them must fail.
  while IFS= read -r spec; do
    [[ -n $spec ]] || continue
    IFS='#' read -r -a f <<<"$spec"
    mname=${f[0]}
    m=$tmp/mut
    rm -rf "$m"
    mkdir -p "$m/bridges" "$m/apps" "$m/tests/unit"
    cp -a "$root/bridges/prompter" "$m/bridges/"
    cp -a "$root/tests/unit/prompter" "$m/tests/unit/"
    cp "$root/apps/runmode.h" "$root/apps/testbus.h" "$m/apps/"
    mkdir -p "$m/ui/i18n"
    cp "$root/ui/i18n/translationloader.h" "$m/ui/i18n/" # grassfield-askpass's (step 9c)
    cp "$root/VERSION" "$m/VERSION"
    git -C "$m" init -q
    if ! python3 -I - "$m/bridges/prompter/src/${f[1]}" "${f[2]}" "${f[3]}" <<'PY'; then echo "MUTANT $mname: NOT APPLIED"; fail=1; continue; fi
import sys
p, a, b = sys.argv[1], sys.argv[2].replace("\\n", "\n"), sys.argv[3].replace("\\n", "\n")
s = open(p).read()
if s.count(a) != 1:
    sys.exit(3)
open(p, "w").write(s.replace(a, b))
PY
    if ! { bash "$m/bridges/prompter/build-direct.sh" --out "$m/bin" && bash "$m/bridges/prompter/build-direct.sh" --tests --out "$m/bin"; } >"$m/build.log" 2>&1; then
      echo "MUTANT $mname: DOES NOT BUILD"; fail=1; continue
    fi
    if ! "$m/bin/prompter-unit-tests" --gtest_brief=1 >"$m/unit.log" 2>&1; then
      echo "MUTANT $mname: CAUGHT by the unit tests"
    elif ! GRASSFIELD_PROMPTER="$m/bin/grassfield-prompter" bash "$0" >"$m/run.log" 2>&1; then
      echo "MUTANT $mname: CAUGHT by this scenario ($(grep -c '^FAIL' "$m/run.log") failing)"
    else
      echo "MUTANT $mname: NOT CAUGHT"; fail=1
    fi
    rm -rf "$m"
  done <<'EOF_MUTANTS'
name-before-hello#Bridge.cpp#            send(helloMessage(bridgeKinds(m_nm != nullptr, m_kio != nullptr, m_bt != nullptr)));#            send(helloMessage(bridgeKinds(m_nm != nullptr, m_kio != nullptr, m_bt != nullptr)));\n            wantName(true);
lines-not-wiped#Protocol.cpp#            explicit_bzero(buffer + start, end - start + 1);#            ;
rest-not-wiped#Protocol.cpp#            explicit_bzero(buffer + (length - start), start);#            ;
answered-without-a-shell#Bridge.cpp#            return;\n        if (m_client < 0 || !m_ready) {\n            log(#            return;\n        if (false) {\n            log(
pidfd-not-rechecked#Identity.cpp#        facts.alive = pidfdAlive(pidfd);#        facts.alive = true;
every-known-caller-exempt#Identity.cpp#            if (!facts.sameNamespaces && role != QLatin1String("disk"))\n                return r;\n            // KIO's worker runs a plugin from any path#            // KIO's worker runs a plugin from any path
disk-not-exempt#Identity.cpp#            if (!facts.sameNamespaces && role != QLatin1String("disk"))#            if (!facts.sameNamespaces)
EOF_MUTANTS
fi
exit $fail
