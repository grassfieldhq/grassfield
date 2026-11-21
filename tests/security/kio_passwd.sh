#!/usr/bin/env bash
# grassfield-prompter's KIO password server (ADR-0035 D-12 b, owner decision Q11 = K1; step 9e) on a private session bus of
# the test's own, with KIO's REAL client (KF6 KIOCore's KPasswdServerClient, tests/fixtures/kio-passwd-client.cpp built here
# against the installed KF6), KIO's real ftp worker (/usr/lib/kf6/kioworker with kio_ftp) logging in to a local test server
# (tests/fixtures/ftp-login-server.py), a fake shell on the bridge's socket (tests/fixtures/prompter-shell.py), the real
# gnome-keyring as the Secret Service (a throwaway keyring in the scenario's scratch home), a fake Secret Service that is not
# gnome-keyring (tests/fixtures/fake-secret-service.py), a stand-in for kiod6 that D-Bus activation starts, a second listener
# and a stranger (tests/fixtures/kpasswd-peer.py), a worker plugin of the user's own (tests/fixtures/kio-plugin.cpp) and KDE's
# real kiod6 started by D-Bus activation. Never the owner's buses, keyring or secrets: every process runs under env -i
# with the test's scratch directories, the bridge as a development run, which refuses any bus but a private test bus.
#  1 no shell: the bridge does not hold org.kde.kpasswdserver6, and a KIO client's check activates kiod6's stand-in; the
#    listener hears the stand-in's broadcast result (the control for 7)
#  2 a shell that does not draw "kio": the name is not requested (the bridge's hello lists kio)
#  3 kiod6's stand-in holds the name when a shell that draws kio connects: the bridge is queued, says so, KIO's queries go to
#    the stand-in; once it leaves, the bridge holds the name
#  4 a query: the shell gets kind kio (the server, the name field, the realm, retry, Remember, the keyring's protection, the
#    requester resolved from the caller's credentials); its answer reaches KIO's client (the anonymous field turned false)
#  5 addAuthInfo, then a check: answered from the session's cache, no sheet
#  6 Remember: the password is in the real gnome-keyring (libsecret, the item's attributes); with the session's entry
#    removed, a check gets it from the keyring; a query after a failed login says so (retry), ticks Remember and fills the
#    name from the keyring's item; the user's Cancel is kept (the next check gets nothing, no keyring lookup)
#  7 results go to the caller only: the second listener hears none of the bridge's results (only the stand-in's broadcasts)
#  8 a stranger (a Python client) is shown as an unidentified program with its executable; its result comes to it only
#  9 KIO's real worker: kio_ftp asks for the test server's login: requester "kio" (/usr/lib/kf6/kioworker, its text another
#    program's), the server 127.0.0.1:<port>; the login typed in the shell reaches the server; the worker's own
#    addAuthInfo remembers it; a second job logs in without a sheet; a worker plugin of the user's own run by kioworker is
#    an unidentified program, never KIO's row (the security review of step 9e, MINOR-2)
# 10 addAuthInfo with the keyring locked: answered at once, the keyring's unlock prompt comes to the shell (after the server
#    sheet, in the queue) while the bridge keeps answering other calls; once unlocked, the password is stored
# 11 the keyring's protection: a keyring without a password (Omarchy's plain-text Default_keyring) is "unprotected"; a
#    Secret Service that is not gnome-keyring is "unknown"
# 12 bounds: one caller's ninth and tenth open requests answered at once; the applications' four places of the shell's 8
#    (B-05: NetworkManager and BlueZ keep two each, one connection holds two) shared by gcr's prompts and KIO's sheets
# 13 wrong answers from the shell (a name where none is asked, ok without a password, a choice not offered, an empty
#    password, a refusal carrying a password) each end their query with nothing; the shell's refusal (result "refused",
#    its bound) ends its query with nothing and, unlike the user's Cancel, keeps no cancelled entry: the server's next
#    query gets a sheet
# 14 a name changed in the sheet: the result's URL names it, and the old URL's next query is not blocked
# 15 hide-username-line: no name field, the user name kept; <NoAuthPrompt>: nothing at once, no sheet
# 16 the caller leaves while its query is shown: the shell gets "cancel"
# 17 the shell leaves while a query is shown: KIO's client gets nothing at once; the name is released and the next request
#    activates kiod6's stand-in
# 20 KDE's real kiod6, started for its other names (kssld6) while the bridge holds the name, never takes it: the shell gone,
#    the bridge keeps it and answers at once; a bridge started while kiod6 runs without it takes it; kiod6 gone, the name
#    is released and the next call starts kiod6, which takes it (the security review of step 9e, MINOR-1)
# 21 the keychain's calls (the security review of step 9e, MINOR-3 and NIT-2): a password sent to the keychain stays in
#    memory only while its window lives (a check after that, with the keyring locked, is not answered from memory); the
#    caller of a check whose unlock prompt waits behind a store's leaves: gnome-keyring stays up (it aborts when a queued
#    unlock prompt is dismissed); a store that fails stays in memory for the session; a store holds its place for
#    --kio-store-timeout-ms only; gnome-keyring killed, the stores waiting on it end at once and the next one is remembered
# 18 an AuthInfo over the bounds and KIO's LEGACY "ay" method: InvalidArgs
# 19 no test password, and no sanitizer report (GRASSFIELD_PROMPTER built with build-direct.sh --asan), in the bridge's output
# Needs g++ with the Qt 6 Core, D-Bus and gcr-4 headers, libsecret and KF6 KIOCore (or GRASSFIELD_PROMPTER: a built bridge;
# the KIO fixtures are always built here), dbus-daemon, dbus-send, gdbus, python3 with PyGObject (Gio, Secret 1 and Gcr 4);
# SKIPs without them. 9 SKIPs without kio_ftp; 6, 10, 11 and 21 without gnome-keyring-daemon; 20 without kiod6.
#
#   tests/security/kio_passwd.sh              PASS / FAIL lines, exit 0 when all pass
#   tests/security/kio_passwd.sh --mutants    also mutants of the server's guards (and of the cache key, against the unit
#                                             tests), which the checks must catch
set -uo pipefail
umask 077
root=$(git -C "$(dirname "$0")" rev-parse --show-toplevel)
mutants=0
case ${1:-} in
  "") ;;
  --mutants) mutants=1 ;;
  *) echo "usage: kio_passwd.sh [--mutants]" >&2; exit 2 ;;
esac
for tool in dbus-daemon dbus-send gdbus python3 g++ pkg-config; do
  command -v "$tool" >/dev/null || { echo "SKIP: kio_passwd needs $tool"; exit 0; }
done
python3 -I -c 'import gi; gi.require_version("Gio", "2.0"); gi.require_version("Secret", "1"); gi.require_version("Gcr", "4"); from gi.repository import Gio, Secret, Gcr' 2>/dev/null \
  || { echo "SKIP: kio_passwd needs PyGObject with Secret 1 and Gcr 4"; exit 0; }
[[ -r /usr/include/KF6/KIOCore/kpasswdserverclient.h ]] && pkg-config --exists Qt6Core Qt6DBus gcr-4 libsecret-1 2>/dev/null \
  || { echo "SKIP: kio_passwd needs KF6 KIOCore, Qt 6 Core and D-Bus, gcr-4 and libsecret headers"; exit 0; }
leaf=$(awk -F: '$1 == "0" {print $3}' /proc/self/cgroup | sed 's#.*/##')
[[ -n $leaf ]] || { echo "SKIP: kio_passwd: this process sits at the root of its cgroup tree (no unit to stand for the shell's)"; exit 0; }

pids=()
bus_pids=()
tmp=""
d=""
cleanup() {
  local p
  for p in "${pids[@]}"; do kill "$p" 2>/dev/null; done
  for p in "${bus_pids[@]}"; do kill -TERM -- "-$p" 2>/dev/null; done
  [[ -n $d ]] && pkill -f "$d/" 2>/dev/null
  # A bridge blocked in its main loop (the sync-store mutant) never reads its SIGTERM: whatever is left is killed.
  sleep 0.5
  for p in "${pids[@]}"; do kill -KILL "$p" 2>/dev/null; done
  [[ -n $d ]] && pkill -KILL -f "$d/" 2>/dev/null
  wait 2>/dev/null
  [[ -n $tmp ]] && rm -rf "$tmp"
  [[ -n $d ]] && rm -rf "$d"
  pids=()
  bus_pids=()
  tmp=""
  d=""
}

scenario() {
  scenario_body "$@"
  local rc=$?
  cleanup
  return $rc
}

scenario_body() {
  local bridge=$1
  tmp=$(mktemp -d "${GRASSFIELD_TEST_TMP:-${TMPDIR:-/tmp}}/kio-passwd.XXXXXX")
  d=$(mktemp -d /tmp/gfk.XXXXXX)
  local fail=0
  # A mutant's run (KIO_FAST=1, in a subshell) stops at its first failure: one is enough to catch it.
  check() {
    if "$@"; then echo "PASS: $desc"; else
      echo "FAIL: $desc"
      fail=1
      [[ ${KIO_FAST:-} == 1 ]] && { cleanup; exit 1; }
    fi
  }
  wait_until() { local n=$(($1 * 10)); shift; while ((n-- > 0)); do "$@" && return 0; sleep 0.1; done; return 1; }

  mkdir -p "$d/services" "$d/run" "$d/gk/data"
  printf '%s\n' '<!DOCTYPE busconfig PUBLIC "-//freedesktop//DTD D-Bus Bus Configuration 1.0//EN" "http://www.freedesktop.org/standards/dbus/1.0/busconfig.dtd">' \
    '<busconfig>' '  <type>session</type>' "  <listen>unix:path=$d/bus.sock</listen>" '  <auth>EXTERNAL</auth>' \
    "  <servicedir>$d/services</servicedir>" '  <policy context="default">' '    <allow send_destination="*" eavesdrop="true"/>' \
    '    <allow eavesdrop="true"/>' '    <allow own="*"/>' '  </policy>' '</busconfig>' >"$d/bus.conf"
  setsid env -i PATH="$PATH" HOME="$d" XDG_RUNTIME_DIR="$d/run" dbus-daemon --config-file="$d/bus.conf" --nofork --print-address=1 \
    >"$d/bus.address" 2>"$d/bus.log" </dev/null &
  bus_pids+=("$!")
  wait_until 5 test -s "$d/bus.address" || { echo "SKIP: kio_passwd: no private dbus-daemon"; return 0; }
  local bus
  bus=$(head -n 1 "$d/bus.address")
  dbus-send --bus="$bus" --print-reply --dest=org.freedesktop.DBus /org/freedesktop/DBus org.freedesktop.DBus.GetId >/dev/null 2>&1 \
    || { echo "SKIP: kio_passwd: libdbus cannot reach the private bus"; return 0; }
  local env_base=(env -i PATH="$PATH" HOME="$d/gk" XDG_DATA_HOME="$d/gk/data" XDG_RUNTIME_DIR="$d/run" DBUS_SESSION_BUS_ADDRESS="$bus"
    GF_TEST_BUS=1 GF_TEST_BUS_DIR="$d" LC_ALL=C.UTF-8 QT_QPA_PLATFORM=offscreen)
  local sock=$d/run/grassfield/prompter.sock
  local shell_py=$root/tests/fixtures/prompter-shell.py peer_py=$root/tests/fixtures/kpasswd-peer.py gcr_py=$root/tests/fixtures/prompter-client.py

  # kiod6's stand-in, started by D-Bus activation as kiod6 is (org.kde.kpasswdserver6.service).
  {
    printf '#!/bin/sh\n'
    printf 'export PATH=%q HOME=%q DBUS_SESSION_BUS_ADDRESS=%q GF_TEST_BUS_DIR=%q\n' "$PATH" "$d" "$bus" "$d"
    printf 'exec python3 -I %q kiod --log %q\n' "$peer_py" "$d/kiod.log"
  } >"$d/kiod.sh"
  chmod 700 "$d/kiod.sh"
  printf '[D-BUS Service]\nName=org.kde.kpasswdserver6\nExec=%s\n' "$d/kiod.sh" >"$d/services/org.kde.kpasswdserver6.service"
  dbus-send --bus="$bus" --print-reply --dest=org.freedesktop.DBus /org/freedesktop/DBus org.freedesktop.DBus.ReloadConfig >/dev/null 2>&1

  # helpers
  owner() { gdbus call --address "$bus" -d org.freedesktop.DBus -o /org/freedesktop/DBus -m org.freedesktop.DBus.GetNameOwner "$1" 2>/dev/null | sed -n "s/^('\(.*\)',)$/\1/p"; }
  owned() { [[ -n $(owner "$1") ]]; }
  shell_up() { # <tag>
    mkfifo "$d/$1.cmd"
    python3 -I "$shell_py" --socket "$sock" --log "$d/$1.shell" --commands "$d/$1.cmd" </dev/null >/dev/null 2>&1 &
    pids+=("$!")
    wait_until 5 grep -q '^#connect' "$d/$1.shell" 2>/dev/null
  }
  say() { timeout 5 bash -c 'printf "%s\n" "$2" >"$1"' _ "$d/$1.cmd" "$2"; }
  client_up() { # <tag>: KIO's real client, its commands on <tag>.cmd, its results in <tag>.out
    mkfifo "$d/$1.cmd"
    "${env_base[@]}" "$tmpb/bin/kio-passwd-client" <>"$d/$1.cmd" >"$d/$1.out" 2>"$d/$1.err" &
    pids+=("$!")
  }
  peer_up() { # <tag> <role>
    mkfifo "$d/$1.cmd"
    "${env_base[@]}" python3 -I "$peer_py" "$2" --log "$d/$1.log" --commands "$d/$1.cmd" </dev/null >/dev/null 2>"$d/$1.err" &
    pids+=("$!")
    wait_until 5 grep -q '^#ready\|^#owned\|^#not-owned' "$d/$1.log" 2>/dev/null
  }
  lines() { [[ -f $1 ]] && wc -l <"$1" || echo 0; }
  ask() { # <client tag> <command>: waits for its one result line, prints it
    local before
    before=$(lines "$d/$1.out")
    say "$1" "$2"
    wait_until "${3:-15}" bash -c '[[ $(wc -l <"$1") -gt $2 ]]' _ "$d/$1.out" "$before" && tail -n 1 "$d/$1.out"
  }
  prompts() { grep -c '"type":"prompt"' "$d/$1.shell" 2>/dev/null; }
  wait_prompt() { # <shell tag> <count before>
    wait_until "${3:-10}" bash -c '[[ $(grep -c "\"type\":\"prompt\"" "$1") -gt $2 ]]' _ "$d/$1.shell" "$2"
  }
  last_prompt() { grep '"type":"prompt"' "$d/$1.shell" | tail -n 1 | python3 -I -c "import json,sys; m=json.loads(sys.stdin.read()); print($2)"; }
  last_id() { last_prompt "$1" 'm["id"]'; }
  kc_lookup() { # <key> <realm> <user>: the password the real keyring holds (test values only)
    "${env_base[@]}" python3 -I -c '
import sys, gi
gi.require_version("Secret", "1")
from gi.repository import Secret
s = Secret.Schema.new("org.grassfield.NetworkPassword", Secret.SchemaFlags.NONE, {k: Secret.SchemaAttributeType.STRING for k in ("key", "realm", "user", "protocol", "server", "port")})
items = Secret.password_search_sync(s, {"key": sys.argv[1], "realm": sys.argv[2], "user": sys.argv[3]}, Secret.SearchFlags.LOAD_SECRETS, None)
print(items[0].retrieve_secret_sync(None).get_text() if items and not items[0].get_locked() else ("locked" if items else "none"))' "$@" 2>/dev/null
  }
  kc_is() { [[ $(kc_lookup "$1" "$2" "$3") == "$4" ]]; }
  have_keyring=0
  local fakess_pid=""
  command -v gnome-keyring-daemon >/dev/null && have_keyring=1
  gk_up() { # [--unlock]: the real gnome-keyring in the scratch home, unlocked with a throwaway password
    if [[ ${1:-} == --unlock ]]; then
      printf %s throwaway | "${env_base[@]}" gnome-keyring-daemon --foreground --unlock --components=secrets >>"$d/gk.log" 2>&1 &
    else
      "${env_base[@]}" gnome-keyring-daemon --foreground --components=secrets </dev/null >>"$d/gk.log" 2>&1 &
    fi
    gk_pid=$!
    pids+=("$gk_pid")
    wait_until 10 owned org.freedesktop.secrets
  }

  # --- the bridge, gnome-keyring, the listener ---------------------------------------------------------------------------
  if ((have_keyring)); then
    gk_up --unlock || { echo "FAIL: gnome-keyring starts on the private bus"; fail=1; have_keyring=0; }
  fi
  # Leaks are not judged when 20 stops this bridge: libsecret never completes the calls sent to the gnome-keyring 21 kills,
  # cancelled or not (decision 9-50); every other sanitizer report still is.
  "${env_base[@]}" GRASSFIELD_DEV=1 ASAN_OPTIONS=detect_leaks=0 "$bridge" --socket "$sock" --peer-unit "$leaf" --kio-store-timeout-ms 4000 >"$d/bridge.log" 2>&1 &
  local bridge_pid=$!
  pids+=("$bridge_pid")
  wait_until 5 test -S "$sock"
  wait_until 5 grep -q "KIO's password server ready" "$d/bridge.log"
  local bridge_name
  bridge_name=$(sed -n 's/^grassfield-prompter: [^ ]* prompter\/1 on \(:[0-9.]*\) .*/\1/p' "$d/bridge.log")
  peer_up listen listener
  client_up c

  # --- 1 no shell: kiod6's stand-in by activation ------------------------------------------------------------------------
  desc="without a shell the bridge does not hold org.kde.kpasswdserver6"
  check bash -c '[[ -n $2 ]] && ! grep -q "kpasswdserver6 acquired" "$1"' _ "$d/bridge.log" "$bridge_name"
  local out
  out=$(ask c "check sftp://example.org/home")
  desc="...and a KIO client's check activates kiod6's stand-in, which answers it [$out]"
  check bash -c '[[ $1 == *"user=kiod-standin"* ]] && grep -q "^#owned" "$2"' _ "$out" "$d/kiod.log"
  desc="...whose result, broadcast as kpasswdserver does, the second listener hears (the control for 7)"
  check wait_until 5 grep -q "^signal checkAuthInfoAsyncResult [0-9]* user=kiod-standin" "$d/listen.log"
  pkill -f "$peer_py kiod" 2>/dev/null
  wait_until 5 bash -c '! gdbus call --address "$1" -d org.freedesktop.DBus -o /org/freedesktop/DBus -m org.freedesktop.DBus.GetNameOwner org.kde.kpasswdserver6 >/dev/null 2>&1' _ "$bus"

  # --- 2 a shell that does not draw kio ------------------------------------------------------------------------------------
  shell_up s0
  say s0 "hello password confirm"
  wait_until 5 grep -q '"type":"name"' "$d/s0.shell"
  sleep 0.5
  desc="a shell that does not draw kio: the name is not requested, though the bridge's hello lists kio"
  check bash -c '! grep -q "kpasswdserver6 acquired" "$1" && [[ -z $3 ]] && grep -q "\"kinds\":\[\"password\",\"confirm\",\"kio\"\]" "$2"' _ "$d/bridge.log" "$d/s0.shell" "$(owner org.kde.kpasswdserver6)"
  say s0 close
  wait_until 5 grep -q "shell gone" "$d/bridge.log"

  # --- 3 kiod6 holds the name first ---------------------------------------------------------------------------------------
  "${env_base[@]}" python3 -I "$peer_py" kiod --log "$d/kiod2.log" </dev/null >/dev/null 2>&1 &
  local kiod_pid=$!
  pids+=("$kiod_pid")
  wait_until 5 grep -q '^#owned' "$d/kiod2.log" 2>/dev/null
  shell_up s
  say s "hello password confirm kio"
  desc="kiod6 holds the name when a shell that draws kio connects: the bridge is queued behind it and says so"
  check wait_until 5 grep -q "kpasswdserver6 is held by another program.*queued behind it" "$d/bridge.log"
  local n
  n=$(prompts s)
  out=$(ask c "query sftp://example.org/home - - keep skipcache")
  desc="...KIO's query goes to kiod6 meanwhile, nothing reaches the shell [$out]"
  check bash -c '[[ $1 == *"user=kiod-standin"* && $(grep -c "\"type\":\"prompt\"" "$2") == "$3" ]]' _ "$out" "$d/s.shell" "$n"
  kill "$kiod_pid" 2>/dev/null
  desc="...once it leaves the bus, the bridge holds the name"
  check wait_until 5 bash -c 'grep -q "kpasswdserver6 acquired" "$1" && [[ $(gdbus call --address "$2" -d org.freedesktop.DBus -o /org/freedesktop/DBus -m org.freedesktop.DBus.GetNameOwner org.kde.kpasswdserver6) == *"$3"* ]]' _ "$d/bridge.log" "$bus" "$bridge_name"

  # --- 4 a query through the shell -------------------------------------------------------------------------------------
  n=$(prompts s)
  say c "query sftp://example.org/home - - keep skipcache anon"
  wait_prompt s "$n"
  local expect_keyring=unknown
  ((have_keyring)) && expect_keyring=protected
  desc="a query: the shell gets kind kio, its server, an empty name to type, no realm, no retry, Remember off, the keyring $expect_keyring"
  check test "$(last_prompt s '"|".join((m["kind"], ",".join(sorted(m)), m["server"], ",".join(sorted(m["login"])), m["login"]["name"], m["login"]["nameMode"], m["login"]["realm"], str(m["login"]["retry"]), m["login"]["remember"], m["login"]["keyring"]))')" \
    = "kio|id,kind,login,requester,server,type|example.org|keyring,name,nameMode,realm,remember,retry||edit||False|off|$expect_keyring"
  desc="...who asks is resolved from the caller's credentials: KIO's client here is an unidentified program, its executable named"
  check test "$(last_prompt s '"|".join((m["requester"]["role"], m["requester"]["path"], str(m["requester"]["identified"])))')" = "unidentified|$tmpb/bin/kio-passwd-client|False"
  say s "answer last kio alice yes correct horse 9"
  wait_until 10 bash -c '[[ $(wc -l <"$1") -ge 3 ]]' _ "$d/c.out"
  out=$(tail -n 1 "$d/c.out")
  desc="...the name and the password typed reach KIO's client, Remember as keepPassword, the anonymous field false [$out]"
  check bash -c '[[ $1 == "query rc=0 modified=1 user=alice password=correct horse 9 keep=1 anon=false url=sftp://example.org/home" ]]' _ "$out"

  # --- 5 addAuthInfo and the session's cache ------------------------------------------------------------------------------
  out=$(ask c "add sftp://example.org/home alice correct_horse_9 keep")
  n=$(prompts s)
  out=$(ask c "check sftp://example.org/home")
  desc="addAuthInfo, then a check: answered from the session's cache, without a sheet [$out]"
  check bash -c '[[ $1 == "check found=1 modified=1 user=alice password=correct_horse_9 "* && $(grep -c "\"type\":\"prompt\"" "$2") == "$3" ]] && grep -q "answered from the session.s cache" "$4"' _ "$out" "$d/s.shell" "$n" "$d/bridge.log"

  # --- 6 Remember, through the real gnome-keyring ------------------------------------------------------------------------
  if ((have_keyring)); then
    desc="Remember: the password is in the real gnome-keyring under the item's attributes (key, realm, user)"
    check wait_until 10 kc_is "sftp-example.org:-1" "" alice correct_horse_9
    ask c "remove example.org sftp alice" >/dev/null
    n=$(prompts s)
    out=$(ask c "check sftp://example.org/home")
    desc="...with the session's entry removed (removeAuthInfo), a check gets it from the keyring, without a sheet [$out]"
    check bash -c '[[ $1 == "check found=1 modified=1 user=alice password=correct_horse_9 "* && $(grep -c "\"type\":\"prompt\"" "$2") == "$3" ]] && grep -q "answered with a remembered password" "$4"' _ "$out" "$d/s.shell" "$n" "$d/bridge.log"
    say c "query sftp://example.org/home - Login_failed keep skipcache"
    wait_prompt s "$n"
    desc="...a query after a failed login says so, ticks Remember (the keyring has an item) and fills the name from it"
    check test "$(last_prompt s '"|".join((m["login"]["name"], str(m["login"]["retry"]), m["login"]["remember"], m["login"]["keyring"]))')" = "alice|True|on|protected"
    say s "answer last cancel"
    wait_until 10 bash -c 'tail -n 1 "$1" | grep -q "^query rc=1 modified=0"' _ "$d/c.out"
    out=$(ask c "check sftp://example.org/home")
    desc="...the user's Cancel is kept: the next check gets nothing, and no keyring lookup [$out]"
    check bash -c '[[ $1 == "check found=0 modified=0 "* ]] && [[ $(grep -c "answered with a remembered password" "$2") == 1 ]]' _ "$out" "$d/bridge.log"
  else
    echo "SKIP: kio_passwd: no gnome-keyring-daemon (6, Remember through the real keyring)"
  fi

  # --- 8 a stranger --------------------------------------------------------------------------------------------------------
  peer_up st stranger
  n=$(prompts s)
  say st "query sftp://stranger.example/"
  wait_prompt s "$n"
  local python_exe
  python_exe=$(readlink -f "$(command -v python3)")
  desc="a stranger (a Python client) is an unidentified program, its executable named [$(last_prompt s 'm["requester"]["role"] + " " + m["requester"]["path"]')]"
  check test "$(last_prompt s 'm["requester"]["role"] + "|" + m["requester"]["path"]')" = "unidentified|$python_exe"
  say s "answer last kio mallory no stranger-pass-1"
  desc="...its result comes to it"
  check wait_until 10 grep -q "^result query [0-9]* modified=1 user=mallory password=stranger-pass-1" "$d/st.log"

  # --- 9 KIO's real worker ------------------------------------------------------------------------------------------------
  if [[ -x /usr/lib/kf6/kioworker && -e /usr/lib/qt6/plugins/kf6/kio/kio_ftp.so ]]; then
    "${env_base[@]}" python3 -I "$root/tests/fixtures/ftp-login-server.py" --port-file "$d/ftp.port" --log "$d/ftp.log" --user ftpuser --password ftp-pass-7 \
      </dev/null >/dev/null 2>&1 &
    pids+=("$!")
    wait_until 5 test -s "$d/ftp.port"
    local port
    port=$(cat "$d/ftp.port")
    n=$(prompts s)
    "${env_base[@]}" "$tmpb/bin/kio-stat" "ftp://127.0.0.1:$port/" >"$d/stat1.out" 2>"$d/stat1.err" &
    pids+=("$!")
    if wait_prompt s "$n" 30; then
      desc="KIO's real ftp worker asks: requester kio (/usr/lib/kf6/kioworker, its text another program's), the server 127.0.0.1:$port, Remember offered"
      check test "$(last_prompt s '"|".join((m["requester"]["role"], m["requester"]["path"], str(m["requester"]["onBehalf"]), m["server"], m["login"]["nameMode"], m["login"]["remember"]))')" \
        = "kio|/usr/lib/kf6/kioworker|True|127.0.0.1:$port|edit|off"
      say s "answer last kio ftpuser yes ftp-pass-7"
      desc="...the login typed in the shell reaches the server and the job succeeds"
      check wait_until 30 bash -c 'grep -q "^login ok ftpuser" "$1" && grep -qx "stat ok" "$2"' _ "$d/ftp.log" "$d/stat1.out"
      desc="...the worker's own addAuthInfo keeps it, Remember chosen"
      check wait_until 10 grep -q "addAuthInfo (ftp): kept in the session's cache while its window lives, and sent to the keychain" "$d/bridge.log"
      n=$(prompts s)
      "${env_base[@]}" "$tmpb/bin/kio-stat" "ftp://127.0.0.1:$port/" >"$d/stat2.out" 2>"$d/stat2.err"
      desc="...a second job logs in without a sheet [$(cat "$d/stat2.out")]"
      check bash -c 'grep -qx "stat ok" "$1" && [[ $(grep -c "\"type\":\"prompt\"" "$2") == "$3" && $(grep -c "^login ok ftpuser" "$4") -ge 2 ]]' _ "$d/stat2.out" "$d/s.shell" "$n" "$d/ftp.log"
      # A worker plugin of the user's own: kioworker loads it from any path (kioworker.cpp:49-65); KIO's row needs trusted code.
      n=$(prompts s)
      "${env_base[@]}" /usr/lib/kf6/kioworker "$tmpb/bin/kio-plugin.so" smb x y >"$d/plugin.out" 2>&1 &
      pids+=("$!")
      wait_prompt s "$n" 15
      desc="a worker plugin of the user's own run by kioworker is an unidentified program (kioworker named), never KIO's row [$(last_prompt s 'm["requester"]["role"] + " " + m["server"]' 2>/dev/null)]"
      check test "$(last_prompt s '"|".join((m["requester"]["role"], m["requester"]["path"], str(m["requester"]["identified"]), m["server"]))')" \
        = "unidentified|/usr/lib/kf6/kioworker|False|plugin.example"
      say s "answer last cancel"
      wait_until 10 grep -q "^plugin result" "$d/plugin.out"
    else
      echo "FAIL: KIO's real ftp worker asks the shell [$(cat "$d/stat1.out" "$d/stat1.err" 2>/dev/null | head -5)] [$(tail -n 5 "$d/bridge.log" | tr '\n' '|')] [$(tr '\n' '|' <"$d/ftp.log")]"
      fail=1
    fi
  else
    echo "SKIP: kio_passwd: no kio_ftp worker (9, KIO's real worker)"
  fi

  # --- 10 addAuthInfo with the keyring locked ------------------------------------------------------------------------------
  if ((have_keyring)); then
    gdbus call --address "$bus" -d org.freedesktop.secrets -o /org/freedesktop/secrets -m org.freedesktop.Secret.Service.Lock \
      "['/org/freedesktop/secrets/collection/login']" >/dev/null 2>&1
    n=$(prompts s)
    say st "add sftp://locked.example/ bob locked-pass-3"
    desc="addAuthInfo with the keyring locked is answered at once [$(grep '^add ' "$d/st.log" | tail -n 1)]"
    check wait_until 5 bash -c 'grep -q "^add replied [0-9]*$" "$1" && (( $(grep "^add replied" "$1" | tail -n 1 | cut -d" " -f3) < 2000 ))' _ "$d/st.log"
    wait_prompt s "$n"
    desc="...the keyring's unlock prompt comes to the shell, as Keyring's, in the queue"
    check test "$(last_prompt s 'm["kind"] + "|" + m["requester"]["role"]')" = "password|keyring"
    local gid
    gid=$(last_id s)
    out=$(ask c "check sftp://elsewhere.example/" 10)
    desc="...the bridge answers other calls meanwhile [$out]"
    check bash -c '[[ $1 == "check found=0 "* ]]' _ "$out"
    say s "answer $gid ok throwaway"
    desc="...once the keyring is unlocked, the password is stored"
    check wait_until 10 kc_is "sftp-locked.example:-1" "" bob locked-pass-3
  fi

  # --- 11 the keyring's protection --------------------------------------------------------------------------------------
  if ((have_keyring)); then
    kill "$gk_pid" 2>/dev/null
    wait_until 5 bash -c '! gdbus call --address "$1" -d org.freedesktop.DBus -o /org/freedesktop/DBus -m org.freedesktop.DBus.GetNameOwner org.freedesktop.secrets >/dev/null 2>&1' _ "$bus"
    rm -f "$d/gk/data/keyrings/"*
    printf '[keyring]\ndisplay-name=Default keyring\nctime=1700000000\nmtime=0\nlock-on-idle=false\nlock-after=false\n' >"$d/gk/data/keyrings/Default_keyring.keyring"
    printf 'Default_keyring\n' >"$d/gk/data/keyrings/default"
    gk_up
    n=$(prompts s)
    say c "query sftp://plain.example/ - - keep skipcache"
    wait_prompt s "$n"
    desc="a keyring without a password (Omarchy's plain-text Default_keyring): \"unprotected\""
    check test "$(last_prompt s 'm["login"]["keyring"]')" = unprotected
    say s "answer last cancel"
    wait_until 10 bash -c 'tail -n 1 "$1" | grep -q "^query rc=1"' _ "$d/c.out"
    kill "$gk_pid" 2>/dev/null
    wait_until 5 bash -c '! gdbus call --address "$1" -d org.freedesktop.DBus -o /org/freedesktop/DBus -m org.freedesktop.DBus.GetNameOwner org.freedesktop.secrets >/dev/null 2>&1' _ "$bus"
    "${env_base[@]}" python3 -I "$root/tests/fixtures/fake-secret-service.py" keychain --log "$d/fakess.log" </dev/null >/dev/null 2>&1 &
    fakess_pid=$!
    pids+=("$fakess_pid")
    wait_until 10 owned org.freedesktop.secrets
    n=$(prompts s)
    say c "query sftp://other-service.example/ - - keep skipcache"
    wait_prompt s "$n"
    desc="a Secret Service that is not gnome-keyring: \"unknown\""
    check test "$(last_prompt s 'm["login"]["keyring"]')" = unknown
    say s "answer last cancel"
    wait_until 10 bash -c 'tail -n 1 "$1" | grep -q "^query rc=1"' _ "$d/c.out"
  fi

  # --- 12 bounds ------------------------------------------------------------------------------------------------------------
  n=$(prompts s)
  local before
  before=$(grep -c '^result query' "$d/st.log")
  say st "many 10 sftp://many.example/"
  wait_prompt s "$n"
  desc="one caller's ninth and tenth open requests are answered with nothing at once, the shell shown one sheet"
  check wait_until 5 bash -c '[[ $(( $(grep -c "^result query [0-9]* modified=0" "$1") )) -ge 2 && $(grep -c "\"type\":\"prompt\"" "$2") == $(( $3 + 1 )) ]]' _ "$d/st.log" "$d/s.shell" "$n"
  say s "answer last cancel"
  desc="...the user's Cancel answers the other seven without a sheet (kept as a cancelled entry, as kpasswdserver does)"
  check wait_until 10 bash -c '[[ $(( $(grep -c "^result query" "$1") - $2 )) == 10 ]]' _ "$d/st.log" "$before"
  # The applications' share of the shell's 8 places (B-05, bridges/prompter/src/Requests.h): NetworkManager and BlueZ keep
  # two each, so gcr prompts and KIO sheets together hold at most four, and one connection at most two.
  n=$(prompts s)
  "${env_base[@]}" python3 -I "$gcr_py" many 7 >"$d/gcr.out" 2>&1 &
  pids+=("$!")
  wait_prompt s $((n + 1))
  desc="one gcr connection with seven prompts: the shell gets two, the other five are answered \"cancelled\" at once (B-05)"
  check wait_until 10 bash -c '[[ $(grep -c "cancelled" "$1") == 5 && $(( $(grep -c "\"type\":\"prompt\"" "$2") - $3 )) == 2 ]]' _ "$d/gcr.out" "$d/s.shell" "$n"
  "${env_base[@]}" python3 -I "$gcr_py" many 1 >"$d/gcr2.out" 2>&1 &
  pids+=("$!")
  wait_prompt s $((n + 2))
  say c "query sftp://bound.example/ - - keep"
  wait_prompt s $((n + 3))
  before=$(grep -c '^result query' "$d/st.log")
  say st "many 1 sftp://bound2.example/"
  desc="the applications' four places are shared by gcr and KIO: three gcr prompts and a KIO sheet, the next KIO query gets nothing at once"
  check wait_until 10 bash -c '[[ $(( $(grep -c "^result query [0-9]* modified=0" "$1") )) -gt 0 && $(grep -c "^result query" "$1") -gt $2 ]] && grep -q "kio request answered with nothing: 4 requests are outstanding" "$3"' _ "$d/st.log" "$before" "$d/bridge.log"
  desc="...and the shell was shown four sheets, no more"
  check bash -c '[[ $(( $(grep -c "\"type\":\"prompt\"" "$1") - $2 )) == 4 ]]' _ "$d/s.shell" "$n"
  for gid in $(grep '"type":"prompt"' "$d/s.shell" | tail -n 4 | python3 -I -c 'import json,sys; [print(json.loads(l)["id"]) for l in sys.stdin]'); do
    say s "answer $gid cancel"
  done
  wait_until 10 bash -c 'tail -n 1 "$1" | grep -q "^query rc=1"' _ "$d/c.out"

  # --- 13 wrong answers from the shell ------------------------------------------------------------------------------------
  local wrong line
  for wrong in name nopass choice empty refusedpass; do
    n=$(prompts s)
    case $wrong in
      name) say c "query sftp://wrong-$wrong.example/ fixeduser - readonly keep" ;;
      choice) say c "query sftp://wrong-$wrong.example/ - -" ;;
      *) say c "query sftp://wrong-$wrong.example/ - - keep" ;;
    esac
    wait_prompt s "$n"
    gid=$(last_id s)
    case $wrong in
      name) line="{\"type\":\"answer\",\"id\":\"$gid\",\"result\":\"ok\",\"identity\":\"eve\",\"password\":\"pw-$wrong\"}" ;;
      nopass) line="{\"type\":\"answer\",\"id\":\"$gid\",\"result\":\"ok\",\"identity\":\"eve\"}" ;;
      choice) line="{\"type\":\"answer\",\"id\":\"$gid\",\"result\":\"ok\",\"identity\":\"eve\",\"password\":\"pw-$wrong\",\"choice\":true}" ;;
      empty) line="{\"type\":\"answer\",\"id\":\"$gid\",\"result\":\"ok\",\"identity\":\"eve\",\"password\":\"\"}" ;;
      refusedpass) line="{\"type\":\"answer\",\"id\":\"$gid\",\"result\":\"refused\",\"password\":\"pw-$wrong\"}" ;;
    esac
    before=$(lines "$d/c.out")
    say s "raw $line"
    wait_until 10 bash -c '[[ $(wc -l <"$1") -gt $2 ]]' _ "$d/c.out" "$before"
    out=$(tail -n 1 "$d/c.out")
    desc="a wrong answer ($wrong) ends its query with nothing, the shell told \"cancel\" [$out]"
    check bash -c '[[ $1 == "query rc=1 modified=0 "* ]] && grep -q "{\"id\":\"$3\",\"type\":\"cancel\"}" "$2"' _ "$out" "$d/s.shell" "$gid"
  done
  # The shell's refusal: two queries of one server (windows 1 and 2, sequence number 0), the first shown and refused. After
  # the user's Cancel the second would be answered with nothing at once (a cancelled entry newer than it, as in 12).
  n=$(prompts s)
  before=$(grep -c '^result query' "$d/st.log")
  say st "many 2 sftp://refused.example/"
  wait_prompt s "$n"
  gid=$(last_id s)
  say s "raw {\"type\":\"answer\",\"id\":\"$gid\",\"result\":\"refused\"}"
  desc="the shell's refusal ends its query with nothing (the shell not told \"cancel\") and keeps no cancelled entry: the server's second query gets a sheet"
  check wait_until 10 bash -c '[[ $(grep -c "^result query [0-9]* modified=0" "$1") -gt 0 && $(( $(grep -c "^result query" "$1") - $2 )) == 1 && $(grep -c "\"type\":\"prompt\"" "$3") == $(( $4 + 2 )) ]] && grep -q "request $5 refused by the shell" "$6" && ! grep -q "{\"id\":\"$5\",\"type\":\"cancel\"}" "$3"' _ "$d/st.log" "$before" "$d/s.shell" "$n" "$gid" "$d/bridge.log"
  say s "answer last cancel"
  wait_until 10 bash -c '[[ $(( $(grep -c "^result query" "$1") - $2 )) == 2 ]]' _ "$d/st.log" "$before"

  # --- 14 a name changed in the sheet -----------------------------------------------------------------------------------
  n=$(prompts s)
  say c "query sftp://alice@change.example/ - - keep skipcache"
  wait_prompt s "$n"
  desc="a URL's user is the name's first text"
  check test "$(last_prompt s 'm["login"]["name"]')" = alice
  before=$(lines "$d/c.out")
  say s "answer last kio bob no change-pass-4"
  wait_until 10 bash -c '[[ $(wc -l <"$1") -gt $2 ]]' _ "$d/c.out" "$before"
  out=$(tail -n 1 "$d/c.out")
  desc="...a name changed in the sheet: the result's URL names it [$out]"
  check bash -c '[[ $1 == "query rc=0 modified=1 user=bob password=change-pass-4 keep=0 anon=none url=sftp://bob@change.example/" ]]' _ "$out"
  n=$(prompts s)
  say c "query sftp://alice@change.example/ - Login_failed keep"
  desc="...and the old URL's next query is not blocked (kpasswdserver leaves its key prompted for ever)"
  check wait_prompt s "$n"
  say s "answer last cancel"
  wait_until 10 bash -c 'tail -n 1 "$1" | grep -q "^query rc=1"' _ "$d/c.out"

  # --- 15 hide-username-line, <NoAuthPrompt> ------------------------------------------------------------------------------
  n=$(prompts s)
  say c "query sftp://pin.example/ keptuser - hidename"
  wait_prompt s "$n"
  desc="hide-username-line: no name field"
  check test "$(last_prompt s 'm["login"]["nameMode"] + "|" + m["login"]["name"]')" = "none|"
  before=$(lines "$d/c.out")
  say s "answer last kio - - pin-pass-5"
  wait_until 10 bash -c '[[ $(wc -l <"$1") -gt $2 ]]' _ "$d/c.out" "$before"
  out=$(tail -n 1 "$d/c.out")
  desc="...the answer carries the password, the user name stays the caller's [$out]"
  check bash -c '[[ $1 == "query rc=0 modified=1 user=keptuser password=pin-pass-5 "* ]]' _ "$out"
  n=$(prompts s)
  out=$(ask c "query sftp://quiet.example/ - - noprompt")
  sleep 0.3
  desc="<NoAuthPrompt>: nothing at once, no sheet [$out]"
  check bash -c '[[ $1 == "query rc=1 modified=0 "* && $(grep -c "\"type\":\"prompt\"" "$2") == "$3" ]]' _ "$out" "$d/s.shell" "$n"

  # --- 16 the caller leaves ---------------------------------------------------------------------------------------------
  n=$(prompts s)
  say st "query sftp://gone.example/"
  wait_prompt s "$n"
  gid=$(last_id s)
  say st quit
  desc="the caller leaves the bus while its query is shown: the shell gets \"cancel $gid\""
  check wait_until 10 grep -q "{\"id\":\"$gid\",\"type\":\"cancel\"}" "$d/s.shell"

  # --- 18 InvalidArgs ----------------------------------------------------------------------------------------------------
  peer_up st2 stranger
  say st2 big
  say st2 legacy
  desc="an AuthInfo over the bounds and KIO's LEGACY addAuthInfo(ay, x): InvalidArgs"
  check wait_until 10 bash -c 'grep -q "^big error org.freedesktop.DBus.Error.InvalidArgs" "$1" && grep -q "^legacy error org.freedesktop.DBus.Error.InvalidArgs" "$1"' _ "$d/st2.log"

  # --- 7 the second listener ---------------------------------------------------------------------------------------------
  desc="results go to the caller only: the second listener heard the stand-in's broadcasts and none of the bridge's"
  check bash -c '[[ $(grep -c "^signal" "$1") -ge 2 && $(grep -c "^signal" "$1") == $(grep -c "^signal .* user=kiod-standin" "$1") ]]' _ "$d/listen.log"

  # --- 21 the keychain's calls (the security review of step 9e, MINOR-3, NIT-2) ------------------------------------------
  if ((have_keyring)); then
    [[ -n $fakess_pid ]] && kill "$fakess_pid" 2>/dev/null
    wait_until 5 bash -c '! gdbus call --address "$1" -d org.freedesktop.DBus -o /org/freedesktop/DBus -m org.freedesktop.DBus.GetNameOwner org.freedesktop.secrets >/dev/null 2>&1' _ "$bus"
    rm -rf "$d/gk/data/keyrings"
    gk_up --unlock
    # gnome-keyring makes its login keyring the default a moment after it took the name
    login_ready() { wait_until 10 bash -c 'gdbus call --address "$1" -d org.freedesktop.secrets -o /org/freedesktop/secrets -m org.freedesktop.Secret.Service.ReadAlias default 2>/dev/null | grep -q collection/login' _ "$bus"; }
    login_ready
    local gk_owner
    gk_owner=$(owner org.freedesktop.secrets)
    ask c "add sftp://keep.example/ kuser keep-pass-1 keep" >/dev/null
    desc="a password sent to the keychain stays in the session's cache only while its window lives (kpasswdserver after a wallet store)"
    check grep -q "addAuthInfo (sftp): kept in the session.s cache while its window lives, and sent to the keychain" "$d/bridge.log"
    wait_until 10 kc_is "sftp-keep.example:-1" "" kuser keep-pass-1
    gdbus call --address "$bus" -d org.freedesktop.secrets -o /org/freedesktop/secrets -m org.freedesktop.Secret.Service.Lock \
      "['/org/freedesktop/secrets/collection/login']" >/dev/null 2>&1
    sleep 10.5 # an entry of no window lives 10 s (kpasswdserver.cpp:703-705)
    n=$(prompts s)
    say st2 "add sftp://store-a.example/ u pw-a"
    wait_prompt s "$n"
    local gid_a
    gid_a=$(last_id s)
    desc="a store into the locked keyring: its unlock prompt in the shell [$(last_prompt s 'm["kind"] + " " + m["requester"]["role"]' 2>/dev/null)]"
    check test "$(last_prompt s 'm["kind"] + "|" + m["requester"]["role"]')" = "password|keyring"
    peer_up chk stranger
    say chk "check sftp://keep.example/"
    wait_until 5 grep -q '^check [0-9]' "$d/chk.log"
    sleep 1.5
    desc="...a check of the remembered server, after its window's time, is not answered from memory while the keyring is locked [$(grep "^result check" "$d/chk.log")]"
    check bash -c '! grep -q "^result check" "$1"' _ "$d/chk.log"
    say chk quit
    sleep 2
    desc="...its caller leaves while its unlock prompt waits behind the store's: gnome-keyring stays up (it aborts when a queued unlock prompt is dismissed)"
    check bash -c 'kill -0 "$1" 2>/dev/null && [[ $2 == "$3" ]]' _ "$gk_pid" "$(owner org.freedesktop.secrets)" "$gk_owner"
    n=$(prompts s)
    say s "answer $gid_a cancel"
    desc="...the store's prompt dismissed by the user: not remembered, kept in memory for the session instead"
    check wait_until 10 grep -q "a password (sftp) could not be remembered.*; kept in the session.s cache for the session" "$d/bridge.log"
    if wait_prompt s "$n" 10; then say s "answer last cancel"; fi # the check's own unlock prompt, its turn come
    sleep 1
    n=$(prompts s)
    local i
    for i in 1 2 3 4 5 6 7 8 9; do say st2 "add sftp://place$i.example/ u pw-p$i"; done
    desc="eight stores waiting on the keyring hold the eight places: the ninth is dropped [$(grep -c "remembering a password" "$d/bridge.log") stores, $(grep -c "dropped" "$d/bridge.log") dropped, $(grep -c "could not be remembered" "$d/bridge.log") failed]"
    check wait_until 10 bash -c '(( $(grep -c "dropped: 8 stores hold a place" "$1") >= 1 ))' _ "$d/bridge.log"
    desc="...after --kio-store-timeout-ms (4 s) a waiting store gives its place up, not cancelled (it may hold gnome-keyring's prompt)"
    check wait_until 10 bash -c '(( $(grep -c "is not remembered yet: no answer from the Secret Service within 4 s" "$1") >= 8 ))' _ "$d/bridge.log"
    local before_stores
    before_stores=$(grep -c "remembering a password" "$d/bridge.log")
    say st2 "add sftp://place10.example/ u pw-p10"
    desc="...and the next store goes"
    check wait_until 5 bash -c '(( $(grep -c "remembering a password" "$1") > $2 ))' _ "$d/bridge.log" "$before_stores"
    local left_before
    left_before=$(grep -c "could not be remembered: the Secret Service left the bus" "$d/bridge.log")
    kill -KILL "$gk_pid" 2>/dev/null
    wait "$gk_pid" 2>/dev/null
    desc="gnome-keyring killed while nine stores wait on it: they end at once, their places freed"
    check wait_until 5 bash -c '(( $(grep -c "could not be remembered: the Secret Service left the bus" "$1") - $2 == 9 ))' _ "$d/bridge.log" "$left_before"
    gk_up --unlock
    login_ready
    say st2 "add sftp://after.example/ u after-pass"
    desc="...and the next store is remembered"
    check wait_until 10 kc_is "sftp-after.example:-1" "" u after-pass
  fi

  # --- 17 the shell leaves ------------------------------------------------------------------------------------------------
  n=$(prompts s)
  say c "query sftp://leave.example/ - - keep"
  wait_prompt s "$n"
  before=$(lines "$d/c.out")
  say s close
  wait_until 10 bash -c '[[ $(wc -l <"$1") -gt $2 ]]' _ "$d/c.out" "$before"
  out=$(tail -n 1 "$d/c.out")
  desc="the shell leaves while a query is shown: KIO's client gets nothing at once [$out]"
  check bash -c '[[ $1 == "query rc=1 modified=0 "* ]]' _ "$out"
  desc="...the name is released"
  check wait_until 5 grep -q "kpasswdserver6 released" "$d/bridge.log"
  rm -f "$d/kiod.log"
  out=$(ask c "check sftp://example.org/home")
  desc="...and the next request activates kiod6's stand-in [$out]"
  check bash -c '[[ $1 == *"user=kiod-standin"* ]] && grep -q "^#owned" "$2"' _ "$out" "$d/kiod.log"

  # --- 20 KDE's real kiod6 started while the bridge holds the name (the security review of step 9e, MINOR-1) -------------
  if [[ -x /usr/lib/kf6/kiod6 ]]; then
    pkill -f "$peer_py kiod" 2>/dev/null # the stand-in 17 started
    wait_until 5 bash -c '! gdbus call --address "$1" -d org.freedesktop.DBus -o /org/freedesktop/DBus -m org.freedesktop.DBus.GetNameOwner org.kde.kpasswdserver6 >/dev/null 2>&1' _ "$bus"
    {
      printf '#!/bin/sh\n'
      printf 'export PATH=%q HOME=%q XDG_RUNTIME_DIR=%q DBUS_SESSION_BUS_ADDRESS=%q QT_QPA_PLATFORM=offscreen\n' "$PATH" "$d/gk" "$d/run" "$bus"
      printf 'exec /usr/lib/kf6/kiod6 >>%q 2>&1\n' "$d/kiod6.log"
    } >"$d/kiod6.sh"
    chmod 700 "$d/kiod6.sh"
    local svc
    for svc in org.kde.kiod6 org.kde.kpasswdserver6 org.kde.kssld6; do
      printf '[D-BUS Service]\nName=%s\nExec=%s\n' "$svc" "$d/kiod6.sh" >"$d/services/$svc.service"
    done
    dbus-send --bus="$bus" --print-reply --dest=org.freedesktop.DBus /org/freedesktop/DBus org.freedesktop.DBus.ReloadConfig >/dev/null 2>&1
    kiod6_pid() { gdbus call --address "$bus" -d org.freedesktop.DBus -o /org/freedesktop/DBus -m org.freedesktop.DBus.GetConnectionUnixProcessID org.kde.kiod6 2>/dev/null | sed -n 's/^(uint32 \([0-9]*\),)$/\1/p'; }
    local acquired
    acquired=$(grep -c "kpasswdserver6 acquired" "$d/bridge.log")
    shell_up s5
    say s5 "hello password confirm kio"
    wait_until 5 bash -c '(( $(grep -c "kpasswdserver6 acquired" "$1") > $2 ))' _ "$d/bridge.log" "$acquired"
    gdbus introspect --address "$bus" -d org.kde.kssld6 -o / >/dev/null 2>&1 # a KF6 app's SSL check starts kiod6
    wait_until 20 bash -c 'gdbus call --address "$1" -d org.freedesktop.DBus -o /org/freedesktop/DBus -m org.freedesktop.DBus.GetNameOwner org.kde.kiod6 >/dev/null 2>&1' _ "$bus"
    local kpid
    kpid=$(kiod6_pid)
    desc="KDE's kiod6, started for kssld6 while the bridge holds org.kde.kpasswdserver6, does not take it [kiod6 $kpid]"
    check bash -c '[[ -n $1 && $2 == "$3" ]]' _ "$kpid" "$(owner org.kde.kpasswdserver6)" "$bridge_name"
    say s5 close
    desc="...the shell gone, the bridge keeps the name: kiod6 would never take it"
    check wait_until 5 bash -c 'grep -q "kpasswdserver6 kept: kiod6 runs without it" "$1"' _ "$d/bridge.log"
    desc="...it still owns org.kde.kpasswdserver6"
    check test "$(owner org.kde.kpasswdserver6)" = "$bridge_name"
    local t0 t1
    t0=$(date +%s%N)
    out=$(ask c "check sftp://example.org/home" 10)
    t1=$(date +%s%N)
    desc="...and KIO's check is answered with nothing at once, not after 25 s of activating a kiod6 that cannot take it [$out, $(( (t1 - t0) / 1000000 )) ms]"
    check bash -c '[[ $1 == "check found=0 "* ]] && (( $2 < 3000 ))' _ "$out" "$(( (t1 - t0) / 1000000 ))"
    kill -TERM "$bridge_pid" 2>/dev/null
    wait_until 10 bash -c '! kill -0 "$1" 2>/dev/null' _ "$bridge_pid"
    "${env_base[@]}" GRASSFIELD_DEV=1 "$bridge" --socket "$sock" --peer-unit "$leaf" >"$d/bridge2.log" 2>&1 &
    pids+=("$!")
    wait_until 5 grep -q "KIO's password server ready" "$d/bridge2.log"
    local bridge2_name
    bridge2_name=$(sed -n 's/^grassfield-prompter: [^ ]* prompter\/1 on \(:[0-9.]*\) .*/\1/p' "$d/bridge2.log")
    desc="a bridge that starts while kiod6 runs without the name takes it, and answers at once"
    check wait_until 10 bash -c 'grep -q "kpasswdserver6 taken: kiod6 runs without it" "$1" && grep -q "kpasswdserver6 acquired" "$1"' _ "$d/bridge2.log"
    desc="...it owns org.kde.kpasswdserver6"
    check test "$(owner org.kde.kpasswdserver6)" = "$bridge2_name"
    out=$(ask c "check sftp://example.org/home" 10)
    desc="...and a KIO check gets nothing at once [$out]"
    check bash -c '[[ $1 == "check found=0 "* ]]' _ "$out"
    kill "$kpid" 2>/dev/null
    desc="kiod6 gone, the bridge releases the name"
    check wait_until 10 bash -c 'grep -q "kiod6 left the bus" "$1" && grep -q "kpasswdserver6 released" "$1"' _ "$d/bridge2.log"
    gdbus call --address "$bus" -d org.kde.kpasswdserver6 -o /modules/kpasswdserver -m org.kde.KPasswdServer.checkAuthInfoAsync \
      "(byte 1, 'sftp://example.org/', '', '', '', '', '', '', '', '', false, false, false, false, @a{s(siv)} {})" 0 0 >/dev/null 2>&1
    desc="...and the next KIO call starts kiod6, which takes it (KDE's dialog, as before step 9e)"
    check bash -c '[[ -n $1 && $1 == "$2" && $1 != "$3" ]]' _ "$(owner org.kde.kpasswdserver6)" "$(owner org.kde.kiod6)" "$bridge2_name"
    kpid=$(kiod6_pid)
    [[ -n $kpid ]] && kill "$kpid" 2>/dev/null
  else
    echo "SKIP: kio_passwd: no /usr/lib/kf6/kiod6 (20, KDE's real kiod6)"
  fi

  # --- 19 nothing secret in the journal ---------------------------------------------------------------------------------
  desc="no test password in the bridge's output"
  check bash -c '! cat "$@" 2>/dev/null | grep -q -e "correct horse" -e correct_horse -e stranger-pass -e ftp-pass -e locked-pass -e change-pass -e pin-pass -e keep-pass -e after-pass -e throwaway -e "pw-"' _ "$d/bridge.log" "$d/bridge2.log"
  desc="no sanitizer report in the bridge's output (a bridge built with build-direct.sh --asan)"
  check bash -c '! cat "$@" 2>/dev/null | grep -q -e "AddressSanitizer" -e "runtime error:"' _ "$d/bridge.log" "$d/bridge2.log"
  return $fail
}

bridge=${GRASSFIELD_PROMPTER:-}
tmpb=$(mktemp -d "${GRASSFIELD_TEST_TMP:-${TMPDIR:-/tmp}}/kio-passwd-bin.XXXXXX")
trap 'cleanup; rm -rf "$tmpb"' EXIT
trap 'exit 130' INT
trap 'exit 143' TERM
mkdir -p "$tmpb/bin"
kio_flags=(-std=c++20 -O1 -g -fPIC -I/usr/include/KF6/KIOCore -I/usr/include/KF6/KIO -I/usr/include/KF6/KCoreAddons)
# shellcheck disable=SC2046
g++ "${kio_flags[@]}" $(pkg-config --cflags Qt6Core Qt6DBus) "$root/tests/fixtures/kio-passwd-client.cpp" -o "$tmpb/bin/kio-passwd-client" \
  -lKF6KIOCore -lKF6CoreAddons $(pkg-config --libs Qt6Core Qt6DBus) >"$tmpb/kio-build.log" 2>&1 \
  || { cat "$tmpb/kio-build.log"; echo "FAIL: KIO's client builds against KF6 KIOCore"; exit 1; }
# shellcheck disable=SC2046
g++ "${kio_flags[@]}" $(pkg-config --cflags Qt6Core Qt6DBus) "$root/tests/fixtures/kio-stat.cpp" -o "$tmpb/bin/kio-stat" \
  -lKF6KIOCore -lKF6CoreAddons $(pkg-config --libs Qt6Core Qt6DBus) >>"$tmpb/kio-build.log" 2>&1 \
  || { cat "$tmpb/kio-build.log"; echo "FAIL: the KIO job builds against KF6 KIOCore"; exit 1; }
# shellcheck disable=SC2046
g++ -shared -fPIC -O1 $(pkg-config --cflags gio-2.0) "$root/tests/fixtures/kio-plugin.cpp" -o "$tmpb/bin/kio-plugin.so" $(pkg-config --libs gio-2.0) \
  >>"$tmpb/kio-build.log" 2>&1 || { cat "$tmpb/kio-build.log"; echo "FAIL: the worker plugin builds"; exit 1; }
if [[ -z $bridge ]]; then
  "$root/bridges/prompter/build-direct.sh" --out "$tmpb/bridge" >"$tmpb/build.log" 2>&1 || { cat "$tmpb/build.log"; echo "FAIL: the bridge builds"; exit 1; }
  bridge=$tmpb/bridge/grassfield-prompter
fi
scenario "$bridge"
rc=$?

if ((mutants)); then
  # Each mutant removes one guard (name, then "bridge" or "unit", a file under bridges/prompter/src, a text that occurs once in
  # it, its replacement; '#'-separated, \n a newline). A "bridge" mutant must fail the scenario above, a "unit" mutant the unit
  # tests (tests/unit/prompter/tst_prompter.cpp, which hold the cache key's and the cache's rules).
  while IFS= read -r spec; do
    [[ -n $spec ]] || continue
    IFS='#' read -r -a f <<<"$spec"
    name=${f[0]}
    m=$tmpb/mut
    rm -rf "$m"
    mkdir -p "$m/bridges" "$m/apps" "$m/ui/i18n" "$m/tests/unit"
    cp -a "$root/bridges/prompter" "$m/bridges/"
    cp -a "$root/tests/unit/prompter" "$m/tests/unit/"
    cp "$root/apps/runmode.h" "$root/apps/testbus.h" "$m/apps/"
    cp "$root/ui/i18n/translationloader.h" "$m/ui/i18n/"
    cp "$root/VERSION" "$m/"
    git -C "$m" init -q
    if ! python3 -I - "$m/bridges/prompter/src/${f[2]}" "${f[3]}" "${f[4]}" <<'PY'; then echo "MUTANT $name: NOT APPLIED"; rc=1; continue; fi
import sys
p, a, b = sys.argv[1], sys.argv[2].replace("\\n", "\n"), sys.argv[3].replace("\\n", "\n")
s = open(p).read()
if s.count(a) != 1:
    sys.exit(3)
open(p, "w").write(s.replace(a, b))
PY
    if [[ ${f[1]} == unit ]]; then
      "$m/bridges/prompter/build-direct.sh" --tests --out "$m/bin" >"$m/build.log" 2>&1 || { echo "MUTANT $name: DOES NOT BUILD"; rc=1; continue; }
      if "$m/bin/prompter-unit-tests" >"$m/run.log" 2>&1; then echo "MUTANT $name: NOT CAUGHT"; rc=1; else echo "MUTANT $name: CAUGHT ($(grep -m 1 '^\[  FAILED  \] Prompter' "$m/run.log"))"; fi
      continue
    fi
    "$m/bridges/prompter/build-direct.sh" --out "$m/bin" >"$m/build.log" 2>&1 || { echo "MUTANT $name: DOES NOT BUILD"; rc=1; continue; }
    if (KIO_FAST=1 scenario "$m/bin/grassfield-prompter") >"$m/run.log" 2>&1; then echo "MUTANT $name: NOT CAUGHT"; rc=1; else echo "MUTANT $name: CAUGHT ($(grep '^FAIL' "$m/run.log" | head -n 1 | cut -c1-150))"; fi
  done <<'EOF_MUTANTS'
broadcast-not-targeted#bridge#KioServer.cpp#g_dbus_connection_emit_signal(m_bus, destination.toUtf8().constData(),#g_dbus_connection_emit_signal(m_bus, nullptr,
caller-not-identified#bridge#KioServer.cpp#            r->requester = requesterFor(factsOf(reply, fds, self->m_options.uid));#            r->requester = requesterFor(factsOf(reply, fds, self->m_options.uid));\n            r->requester.role = QStringLiteral("kio");\n            r->requester.identified = true;\n            r->requester.onBehalf = true;
caller-departure-ignored#bridge#KioServer.cpp#        if (name[0] == ':' && !newOwner[0])#        if (false)
sync-store#bridge#KioServer.cpp#        secret_password_storev_binary(schema(), attributes, SECRET_COLLECTION_DEFAULT, label.toUtf8().constData(), value, store->cancellable, onStored,\n                                      new Call{m_alive, this, {}, {}, id});#        secret_password_storev_binary_sync(schema(), attributes, SECRET_COLLECTION_DEFAULT, label.toUtf8().constData(), value, nullptr, nullptr);
remember-ignored#bridge#KioServer.cpp#        const bool    stored = info.keepPassword && store(key, info);#        const bool    stored = false;
kinds-gate-ignored#bridge#Bridge.cpp#                m_kio->setWanted(m_kinds.contains(QStringLiteral("kio")));#                m_kio->setWanted(true);
keyring-protection-ignored#bridge#KioServer.cpp#                    r->keyring = kio::fileProtection(#                    (void)kio::fileProtection(
name-kept-when-the-shell-goes#bridge#KioServer.cpp#        if (m_nameWanted)\n            m_releaseSource = g_timeout_add(kReleaseDelayMs, onRelease, this);#        if (false)\n            m_releaseSource = g_timeout_add(kReleaseDelayMs, onRelease, this);
user-cancel-not-kept#bridge#KioServer.cpp#            m_cache.add(r->key, r->info, 0, m_seqNr, true);#            ;
kio-row-for-any-plugin#bridge#Identity.cpp#            if (codeChecked && !runsTrustedCodeOnly(facts, where))#            if (false)
kiod6-ignored-at-release#bridge#KioServer.cpp#            if (running && self->m_owned) {#            if (false) {
kiod6-not-repaired#bridge#KioServer.cpp#        if (self && !cancelled(error) && call->generation == self->m_nameGen && !self->m_nameWanted && kiod6 && !nameHeld) {#        if (false) {
kept-after-kiod6-left#bridge#KioServer.cpp#        if (m_forKiod6 && !m_wanted) {#        if (false) {
unlock-search-cancelled-with-its-request#bridge#KioServer.cpp#SECRET_SEARCH_LOAD_SECRETS), unlock, onLookup, call);#SECRET_SEARCH_LOAD_SECRETS), r->cancellable, onLookup, call);
store-places-never-freed#bridge#KioServer.cpp#                    store->holdsPlace = false;\n                    --self->m_storesInFlight;#                    ;
stores-kept-when-the-service-leaves#bridge#KioServer.cpp#            self->secretsOwnerLeft();#            ;
libsecret-session-kept#bridge#KioServer.cpp#        secret_service_disconnect();#        ;
remembered-kept-in-memory#bridge#KioServer.cpp#        if (stored)\n            cached.keepPassword = false;#        if (false)\n            cached.keepPassword = false;
refusal-as-cancel#bridge#Bridge.cpp#            m_kio->abandon(request, QStringLiteral("the shell could not take it"));#            m_kio->userCancel(request);
old-key-left-prompted#bridge#KioServer.cpp#            m_prompted.removeOne(r->promptedKey);#            m_prompted.removeOne(r->key);
no-per-caller-bound#bridge#KioServer.cpp#        if (mine >= kPerCaller)#        if (mine >= 99)
name-where-none-asked-accepted#bridge#Bridge.cpp#        else if (answer.hasIdentity && !asksName)#        else if (false)
cache-not-consulted-by-checks#bridge#KioServer.cpp#        if (entry && !entry->canceled) {\n            m_cache.touch(entry, r->windowId, false);\n            kio::AuthInfo info = entry->info;#        if (false) {\n            m_cache.touch(entry, r->windowId, false);\n            kio::AuthInfo info = entry->info;
key-without-the-port#unit#KioAuth.cpp#        if (port) // -1 when the URL has none, which is true here, as in kpasswdserver.cpp:583-586\n            key += u':' + QString::number(port);#        (void)port;
key-without-the-user#unit#KioAuth.cpp#        if (!url.userName().isEmpty())\n            key += url.userName() + u'@';#        ;
realm-ignored#unit#KioAuth.cpp#(it->info.realm == info.realm && userMatches)#(userMatches)
user-ignored#unit#KioAuth.cpp#            const bool userMatches = info.username.isEmpty() || info.username == it->info.username;#            const bool userMatches = true;
entries-never-expire#unit#KioAuth.cpp#            if (it->expire == CacheEntry::Expire::Time && now > it->expireAt) {#            if (false) {
look-alike-host-shown#unit#KioAuth.cpp#        QString host = url.host(QUrl::EncodeUnicode);#        QString host = url.host();
EOF_MUTANTS
fi
((rc == 0)) && echo "PASS: kio_passwd" || echo "FAIL: kio_passwd"
exit "$rc"
