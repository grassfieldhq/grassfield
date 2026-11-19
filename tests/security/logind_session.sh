#!/usr/bin/env bash
# SS-02 (security-session audit, round 2), offscreen: logind's Lock signal for THIS session locks, and LockedHint follows the
# lock. tests/security/logind_session.d/probe.qml runs the REAL shell/security/idle/LogindSession.qml (with IdleModel.js and
# shell/lib) under Quickshell, NOT a dev session, against stubs first on PATH (busctl answers from the scenario, gdbus follows
# a signal file, setpriv runs its command). Scenarios, one run each:
#   session-id   XDG_SESSION_ID=5: GetSession("5") names the session
#   display      no XDG_SESSION_ID: the user's Display session names it
#   pid          no XDG_SESSION_ID, no Display session: GetSessionByPID(the compositor's pid, from Hyprland's instance lock
#                file in this run's runtime directory) names it
#   dev          a dev session: nothing is asked of logind (no busctl, no gdbus)
# Then what the stubs were asked: the session's object path only is monitored, SetLockedHint false at start, true once the
# lock holds, false once unlocked, in that order, never anything that unlocks. A copy without the Lock handling is a control
# (it must FAIL). No bus, no compositor. Plain shell test: PASS/FAIL lines, non-zero on failure.
set -euo pipefail
root=$(git -C "$(dirname "$0")" rev-parse --show-toplevel)
cd "$root"
unset QT_QPA_PLATFORMTHEME
command -v qs >/dev/null || { echo "SKIP: logind_session needs Quickshell (qs): NOT VERIFIED"; exit 0; }
mkdir -p "$root/.dev"
tmp=$(mktemp -d "$root/.dev/logind-session.XXXXXX")
trap 'pkill -f "$tmp/" 2>/dev/null || true; rm -rf "$tmp"' EXIT
fail=0

stubs=$tmp/stubs
mkdir -p "$stubs"
cat >"$stubs/busctl" <<'SH'
#!/bin/sh
echo "busctl $*" >>"$LOGIND_STUBS/log"
case "$*" in
  *" GetSession s 5") echo 'o "/org/freedesktop/login1/session/_5"' ;;
  *" GetSession s "*) exit 1 ;;
  *"/org/freedesktop/login1/user/self org.freedesktop.login1.User Display")
    if [ "$LOGIND_SCENARIO" = display ]; then echo '(so) "37" "/org/freedesktop/login1/session/_37"'; else echo '(so) "" "/"'; fi ;;
  *" GetSessionByPID u 4242") echo 'o "/org/freedesktop/login1/session/_42"' ;;
  *" GetSessionByPID u "*) exit 1 ;;
  *" SetLockedHint b "*) ;;
  *) exit 1 ;;
esac
SH
cat >"$stubs/gdbus" <<'SH'
#!/bin/sh
echo "gdbus $*" >>"$LOGIND_STUBS/log"
echo "Monitoring signals on object $7 owned by org.freedesktop.login1"
echo "The name org.freedesktop.login1 is owned by :1.3"
touch "$LOGIND_STUBS/signals"
exec tail -n 0 -F "$LOGIND_STUBS/signals" 2>/dev/null
SH
cat >"$stubs/setpriv" <<'SH'
#!/bin/sh
while [ $# -gt 0 ] && [ "$1" != "--" ]; do shift; done
shift
exec "$@"
SH
chmod +x "$stubs"/*

tree() { # <dir> [<find> <replace>]: the module copied (one mutant at most), the probe as shell.qml
  local dir=$1
  mkdir -p "$dir/runtime/hypr/gf-logind" "$dir/home" "$dir/cfg/security/idle"
  chmod 700 "$dir/runtime"
  printf '4242\nwayland-1\n' >"$dir/runtime/hypr/gf-logind/hyprland.lock"
  cp shell/security/idle/LogindSession.qml shell/security/idle/IdleModel.js "$dir/cfg/security/idle/"
  printf 'module qs.security.idle\nLogindSession 1.0 LogindSession.qml\n' >"$dir/cfg/security/idle/qmldir"
  ln -s "$root/shell/lib" "$dir/cfg/lib"
  cp tests/security/logind_session.d/probe.qml "$dir/cfg/shell.qml"
  if [[ $# -ge 3 ]]; then
    python3 -I - "$dir/cfg/security/idle/LogindSession.qml" "$2" "$3" <<'PY' || return 3
import sys
path, old, new = sys.argv[1:4]
text = open(path).read()
if text.count(old) != 1:
    sys.exit(3)
open(path, "w").write(text.replace(old, new))
PY
  fi
}

run() { # <dir> <scenario> <want path> [dev]: the verdict line (the log in <dir>/log)
  local dir=$1 scenario=$2 want=$3 dev=${4:-}
  : >"$stubs/log"; rm -f "$stubs/signals"
  local env_extra=(-u GRASSFIELD_DEV)
  [[ $dev == dev ]] && env_extra=(GRASSFIELD_DEV=1 LOGIND_DEV=1)
  local sid=()
  [[ $scenario == session-id ]] && sid=(XDG_SESSION_ID=5)
  env -u WAYLAND_DISPLAY -u DISPLAY -u DBUS_SESSION_BUS_ADDRESS -u GRASSFIELD_SESSION -u XDG_SESSION_ID "${env_extra[@]}" "${sid[@]}" \
    PATH="$stubs:$PATH" LOGIND_STUBS="$stubs" LOGIND_SCENARIO="$scenario" LOGIND_WANT_PATH="$want" HYPRLAND_INSTANCE_SIGNATURE=gf-logind \
    HOME="$dir/home" XDG_RUNTIME_DIR="$dir/runtime" XDG_CACHE_HOME="$dir/home/.cache" \
    QT_QPA_PLATFORM=offscreen QML_IMPORT_PATH="$root/ui:$root/.dev/build/qml" GRASSFIELD_LANG=en \
    timeout 60 qs -p "$dir/cfg" --no-color >"$dir/log" 2>&1 || true
  grep -m1 -E "logind-session: (PASS|FAIL)" "$dir/log" || echo "logind-session: no verdict"
}

scenario() { # <scenario> <want path> [dev]
  local dir=$tmp/$1 out
  tree "$dir"
  out=$(run "$dir" "$1" "$2" "${3:-}")
  if [[ $out == *"logind-session: PASS"* ]]; then
    echo "PASS: logind session ($1): ${out#*logind-session: PASS }"
  else
    echo "FAIL: logind session ($1): $out"
    sed -n '1,40p' "$dir/log"
    fail=1
  fi
  python3 -I tests/ci/qml_warnings.py <"$dir/log" || { echo "FAIL: logind session ($1): QML runtime errors"; fail=1; }
  cp "$stubs/log" "$dir/stubs.log"
}

scenario session-id /org/freedesktop/login1/session/_5
log=$tmp/session-id/stubs.log
grep -qx "gdbus monitor --system --dest org.freedesktop.login1 --object-path /org/freedesktop/login1/session/_5" "$log" &&
  [[ $(grep -c "^gdbus" "$log") == 1 ]] &&
  echo "PASS: logind session: one watcher, on this session's object path only" || { echo "FAIL: logind session: watcher calls: $(grep ^gdbus "$log")"; fail=1; }
hints=$(sed -n 's#^busctl --system --timeout=5 call org.freedesktop.login1 /org/freedesktop/login1/session/_5 org.freedesktop.login1.Session SetLockedHint b ##p' "$log" | tr '\n' ' ')
[[ $hints == "false true false " ]] && echo "PASS: logind session: LockedHint false at start, true once the lock holds, false once unlocked" || { echo "FAIL: logind session: LockedHint calls '$hints'"; fail=1; }
[[ $(grep -cvE "^(busctl --system --timeout=5 (call org.freedesktop.login1 /org/freedesktop/login1 org.freedesktop.login1.Manager GetSession s 5|call org.freedesktop.login1 /org/freedesktop/login1/session/_5 org.freedesktop.login1.Session SetLockedHint b (true|false))|gdbus monitor .*)$" "$log") == 0 ]] &&
  echo "PASS: logind session: nothing else is asked of logind (no unlock, no other session)" || { echo "FAIL: logind session: other calls: $(cat "$log")"; fail=1; }

scenario display /org/freedesktop/login1/session/_37
scenario pid /org/freedesktop/login1/session/_42
grep -q "GetSessionByPID u 4242" "$tmp/pid/stubs.log" && echo "PASS: logind session: the compositor's pid read from Hyprland's instance lock file" || { echo "FAIL: logind session: no GetSessionByPID 4242"; fail=1; }
scenario dev "" dev
[[ ! -s $tmp/dev/stubs.log ]] && echo "PASS: logind session: a dev session asks logind nothing" || { echo "FAIL: logind session: a dev session asked: $(cat "$tmp/dev/stubs.log")"; fail=1; }

# Control: without the Lock handling the probe must fail (the checks above see the bug).
dir=$tmp/control
tree "$dir" '            root.lockAsked();' '' || { echo "FAIL: logind session control does not apply (stale)"; fail=1; }
out=$(run "$dir" session-id /org/freedesktop/login1/session/_5)
[[ $out == *"logind-session: FAIL"* ]] && echo "PASS: logind session control (no lockAsked) is caught" || { echo "FAIL: logind session control survived: $out"; fail=1; }

exit "$fail"
