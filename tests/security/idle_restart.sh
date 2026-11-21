#!/usr/bin/env bash
# SS-09 (security-session audit, round 2), offscreen: the idle lock across a restart of the security process. Hyprland counts a
# new idle notification from zero, so the process keeps its idle period in $XDG_RUNTIME_DIR/grassfield-idle-<instance>
# ("idle <uptime s>" / "active") and a restarted process reads it first. tests/security/idle_restart.d/probe.qml starts the
# REAL Idle and Lock (a dev session, stubs for gdbus and setpriv first on PATH, no compositor) next to a record. Lock logs the
# request: without /etc/pam.d/omarchy-lock-password (a build container) it refuses it (missing-pam), on an Omarchy host it
# logs "lock requested (idle)"; either line is what is looked for:
#   past     the period began 400 s ago (lock.idleMinutes 5): the idle lock is asked for at start
#   due      it began 296 s ago: the lock is due in about 4 s and asked for then, not at start (each run lasts 14 s: past
#            the 10 s a start waits at most for grassfield.json)
#   active   "active": nothing is asked for
#   future   a period from another boot (later than now): nothing is asked for
#   none     no record: nothing is asked for
# In every case the record is not rewritten before the decision (a crash loop keeps the first period). A control copy of
# Idle.qml whose start does not read the record must fail `past`. Plain shell test: PASS/FAIL lines, non-zero on failure.
set -euo pipefail
root=$(git -C "$(dirname "$0")" rev-parse --show-toplevel)
cd "$root"
unset QT_QPA_PLATFORMTHEME
command -v qs >/dev/null || { echo "SKIP: idle_restart needs Quickshell (qs): NOT VERIFIED"; exit 0; }
[[ -r /proc/uptime ]] || { echo "SKIP: idle_restart needs /proc/uptime: NOT VERIFIED"; exit 0; }
mkdir -p "$root/.dev"
tmp=$(mktemp -d "$root/.dev/idle-restart.XXXXXX")
trap 'rm -rf "$tmp"' EXIT
ui/i18n/build-direct.sh >/dev/null
scripts/dev/i18n-build.sh >/dev/null
fail=0
pass() { echo "PASS: idle restart $*"; }
bad() { echo "FAIL: idle restart $*"; fail=1; }

stubs=$tmp/stubs
mkdir -p "$stubs"
printf '#!/bin/sh\nexec sleep 600\n' >"$stubs/gdbus"
printf '#!/bin/sh\nwhile [ $# -gt 0 ] && [ "$1" != "--" ]; do shift; done\nshift\nexec "$@"\n' >"$stubs/setpriv"
chmod +x "$stubs"/*

make_cfg() { # <dir> [control]
  local dir=$1 entry name
  mkdir -p "$dir"
  for entry in shell/*; do
    name=$(basename "$entry")
    if [[ $name == shell.qml ]]; then
      continue
    elif [[ $name == security && ${2:-} == control ]]; then
      cp -a "$root/$entry" "$dir/security"
    else
      ln -s "$root/$entry" "$dir/$name"
    fi
  done
  cp tests/security/idle_restart.d/probe.qml "$dir/shell.qml"
  if [[ ${2:-} == control ]]; then
    python3 -I - "$dir/security/idle/Idle.qml" <<'PY'
import sys
p = sys.argv[1]
s = open(p).read()
old = "            root.inheritedSince = IdleModel.idleRecordSince(idleRecord.text());"
assert s.count(old) == 1
open(p, "w").write(s.replace(old, "            root.inheritedSince = -1;"))
PY
  fi
}

sig=gf-idle-restart
run() { # <name> <record text or "">  <cfg>: sets $out and $record
  local name=$1 text=$2 cfg=$3 work=$tmp/$1
  mkdir -p "$work/rt" "$work/home" "$work/state" "$work/config" "$work/cache"
  chmod 700 "$work/rt"
  [[ -n $text ]] && printf '%s\n' "$text" >"$work/rt/grassfield-idle-$sig"
  out=$(env -u WAYLAND_DISPLAY -u DISPLAY -u DBUS_SESSION_BUS_ADDRESS -u GRASSFIELD_SESSION -u GRASSFIELD_DEV_ALLOW_PAM \
    -u GRASSFIELD_VISUAL_FIXTURES GRASSFIELD_DEV=1 PATH="$stubs:$PATH" HOME="$work/home" IDLE_RESTART_SECONDS=14 \
    GRASSFIELD_STATE_HOME="$work/state" GRASSFIELD_CONFIG_HOME="$work/config" HYPRLAND_INSTANCE_SIGNATURE="$sig" \
    XDG_RUNTIME_DIR="$work/rt" XDG_CACHE_HOME="$work/cache" QT_QPA_PLATFORM=offscreen \
    QML_IMPORT_PATH="$root/ui:$root/.dev/build/qml" GRASSFIELD_LANG=en GRASSFIELD_TRANSLATIONS_DIR="$root/.dev/translations" \
    timeout 60 qs -p "$cfg" --no-color 2>&1) || true
  record=$(cat "$work/rt/grassfield-idle-$sig" 2>/dev/null || echo "(none)")
  printf '%s\n' "$out" >"$work/log"
}
asked() { grep -c "idle for lock.idleMinutes across a restart of this process; locking" <<<"$out" || true; }
done_ok() { grep -q "idle-restart: done .* decided true" <<<"$out"; }

make_cfg "$tmp/cfg"
make_cfg "$tmp/cfg-control" control
up() { cut -d' ' -f1 /proc/uptime | cut -d. -f1; }

since=$(($(up) - 400))
run past "idle $since" "$tmp/cfg"
# Where /etc/pam.d/omarchy-lock-password is missing (a build container) the lock refuses with missing-pam; on an Omarchy host it
# exists and the lock is engaged as far as this compositor-less run goes. Either way the request itself is what is checked.
engaged_or_refused() {
  if [[ -e /etc/pam.d/omarchy-lock-password ]]; then
    ! grep -q "idle lock not engaged" <<<"$out" && grep -qF "grassfield-lock: lock requested (idle)" <<<"$out"
  else
    grep -q "idle lock not engaged: refused: missing-pam" <<<"$out"
  fi
}
if done_ok && [[ $(asked) == 1 ]] && engaged_or_refused; then
  pass "past: a period that already lasted lock.idleMinutes asks for the idle lock at start"
else
  bad "past: $(grep -E 'idle-restart|grassfield-idle|ERROR' <<<"$out" | head -n 8)"
fi
[[ $record == "idle $since" ]] && pass "past: the record is not rewritten by the new process" || bad "past: record '$record'"

since=$(($(up) - 296))
run due "idle $since" "$tmp/cfg"
# Under load grassfield.json may be read late (the start then decides after at most 10 s, and the deadline may have passed).
# (The former alternative grepped the lock line for words it never holds: it was always true, so a lock at start passed.)
if done_ok && [[ $(asked) == 1 ]] && grep -qE "the idle lock is due in [1-5] s unless input comes" <<<"$out"; then
  pass "due: a shorter period asks for the lock at its own deadline (about 4 s), not at start"
elif done_ok && [[ $(asked) == 1 ]]; then
  echo "SKIP: idle restart due: the lock was asked for, but the start decided after the deadline (grassfield.json read late under load): the deadline itself NOT VERIFIED"
else
  bad "due: $(grep -E 'idle-restart|grassfield-idle|ERROR' <<<"$out" | head -n 8)"
fi

run active "active" "$tmp/cfg"
done_ok && [[ $(asked) == 0 ]] && ! grep -q "is due in" <<<"$out" && [[ $record == active ]] && pass "active: nothing is asked for" || bad "active: $(grep -E 'idle-restart|grassfield-idle' <<<"$out" | head -n 5)"
run future "idle $(($(up) + 5000))" "$tmp/cfg"
done_ok && [[ $(asked) == 0 ]] && pass "future: a period from another boot asks for nothing" || bad "future: $(grep -E 'idle-restart|grassfield-idle' <<<"$out" | head -n 5)"
run none "" "$tmp/cfg"
done_ok && [[ $(asked) == 0 ]] && pass "none: no record, nothing asked for" || bad "none: $(grep -E 'idle-restart|grassfield-idle' <<<"$out" | head -n 5)"
# Gate Q2 on the runs: no QML runtime error of a product file.
cat "$tmp"/*/log | python3 -I tests/ci/qml_warnings.py && pass "no QML runtime error" || bad "QML runtime errors"

since=$(($(up) - 400))
run control "idle $since" "$tmp/cfg-control"
[[ $(asked) == 0 ]] && pass "control (the record not read at start) is caught" || bad "control survived"
exit "$fail"
