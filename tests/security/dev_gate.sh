#!/usr/bin/env bash
# GF-AUDIT-001 SEC-03: the dev/test switches of the lock follow one gate (ADR-0019: shell/lib/RunMode.js dev, which the
# security modules import by a relative path): they work only with GRASSFIELD_DEV=1 AND no GRASSFIELD_SESSION=1. Runs
# tests/security/dev_gate.d/probe.qml offscreen against the REAL Lock singleton (and VisualFixtures, Widgets and qs.lib
# Mode, which must agree with the lock's gate in every environment) in five environments:
#   open                 dev session                                  -> hooks answer, PAM suppressed
#   open, PAM opt-in     dev session + GRASSFIELD_DEV_ALLOW_PAM=1      -> hooks answer, PAM not suppressed (L2 test)
#   closed               real session (GRASSFIELD_SESSION=1)           -> hooks refused, PAM not suppressed
#   closed, leaked dev   real session + GRASSFIELD_DEV=1 (+ ALLOW_PAM) -> the same: a leaked value changes nothing
#   closed, no variable  neither                                      -> hooks refused
# Idle and SleepInhibitor are not started here (they would take a real logind inhibitor with the gate closed): their
# gate is checked in the source by tests/security/ipc_inventory.sh. Plain shell test: PASS/FAIL lines, non-zero on failure.
set -euo pipefail
root=$(git -C "$(dirname "$0")" rev-parse --show-toplevel)
cd "$root"
unset QT_QPA_PLATFORMTHEME
mkdir -p "$root/.dev"
tmp=$(mktemp -d "$root/.dev/dev-gate.XXXXXX")
trap 'rm -rf "$tmp"' EXIT
mkdir -p "$tmp/runtime" "$tmp/cache" "$tmp/home" "$tmp/state" "$tmp/config"
chmod 700 "$tmp/runtime" "$tmp/cache"
ui/i18n/build-direct.sh >/dev/null
scripts/dev/i18n-build.sh >/dev/null
# The probe next to links to every module of the real shell (qs.services needs its siblings).
mkdir -p "$tmp/cfg"
for entry in shell/*; do
  [[ $(basename "$entry") == shell.qml ]] || ln -s "$root/$entry" "$tmp/cfg/$(basename "$entry")"
done
cp tests/security/dev_gate.d/probe.qml "$tmp/cfg/shell.qml"

fail=0
check() { # <label> <expect> env...: one probe run with exactly these Grassfield variables
  local label=$1 expect=$2 out
  shift 2
  out=$(env -u WAYLAND_DISPLAY -u HYPRLAND_INSTANCE_SIGNATURE -u DISPLAY -u DBUS_SESSION_BUS_ADDRESS \
    -u GRASSFIELD_DEV -u GRASSFIELD_SESSION -u GRASSFIELD_DEV_ALLOW_PAM -u GRASSFIELD_VISUAL_FIXTURES \
    DEV_GATE_EXPECT="$expect" "$@" \
    HOME="$tmp/home" GRASSFIELD_STATE_HOME="$tmp/state" GRASSFIELD_CONFIG_HOME="$tmp/config" \
    XDG_RUNTIME_DIR="$tmp/runtime" XDG_CACHE_HOME="$tmp/cache" \
    QT_QPA_PLATFORM=offscreen QML_IMPORT_PATH="$root/ui:$root/.dev/build/qml" GRASSFIELD_LANG=en \
    GRASSFIELD_TRANSLATIONS_DIR="$root/.dev/translations" \
    timeout 60 qs -p "$tmp/cfg" --no-color 2>&1) || true
  if grep -q "dev-gate: PASS" <<<"$out"; then
    echo "PASS: dev gate $label"
  else
    echo "FAIL: dev gate $label: $(grep -E 'dev-gate:|ERROR|WARN qml' <<<"$out" | head -n 5)"
    fail=1
  fi
}

check "open in a dev session" open GRASSFIELD_DEV=1
check "open with the L2 PAM opt-in" open GRASSFIELD_DEV=1 GRASSFIELD_DEV_ALLOW_PAM=1 DEV_GATE_PAM=allowed
check "closed in a real session" closed GRASSFIELD_SESSION=1
check "closed in a real session with a leaked GRASSFIELD_DEV=1" closed GRASSFIELD_SESSION=1 GRASSFIELD_DEV=1 GRASSFIELD_DEV_ALLOW_PAM=1 GRASSFIELD_VISUAL_FIXTURES=1
check "closed without any variable" closed

# Follow-up N1: the marker records the kernel's count of completed suspends; a shell that starts after a sleep it could
# not lock for (crash or restart right before or during it) finds an older count in an "unlocked" marker and locks.
sleeps=$(cat /sys/power/suspend_stats/success 2>/dev/null || true)
marker=$tmp/runtime/grassfield-lock-default
if [[ $sleeps =~ ^[0-9]+$ ]]; then
  printf 'unlocked sleeps=%s\n' "$((sleeps + 1))" >"$marker"
  check "restart after a sleep no shell locked for -> locked" slept GRASSFIELD_SESSION=1
  printf 'unlocked sleeps=%s\n' "$sleeps" >"$marker"
  check "restart without a sleep since the unlock -> unlocked" notslept GRASSFIELD_SESSION=1
  printf 'unlocked\n' >"$marker"
  check "restart with an old marker without a count -> unlocked (no evidence)" notslept GRASSFIELD_SESSION=1
  rm -f "$marker"
else
  echo "SKIP: dev gate sleep cases (/sys/power/suspend_stats/success unreadable here)"
fi

# ADR-0041 S2 (the opus review of 77a0ceb3, MINOR-2): a restarted security process whose marker says "locked" publishes
# "locking" as its first state, never "unlocked" (the first publication comes after the restore, explicitly).
printf 'locked\n' >"$marker"
out=$(env -u WAYLAND_DISPLAY -u HYPRLAND_INSTANCE_SIGNATURE -u DISPLAY -u DBUS_SESSION_BUS_ADDRESS \
  -u GRASSFIELD_DEV -u GRASSFIELD_DEV_ALLOW_PAM -u GRASSFIELD_VISUAL_FIXTURES DEV_GATE_EXPECT=slept GRASSFIELD_SESSION=1 \
  HOME="$tmp/home" GRASSFIELD_STATE_HOME="$tmp/state" GRASSFIELD_CONFIG_HOME="$tmp/config" \
  XDG_RUNTIME_DIR="$tmp/runtime" XDG_CACHE_HOME="$tmp/cache" \
  QT_QPA_PLATFORM=offscreen QML_IMPORT_PATH="$root/ui:$root/.dev/build/qml" GRASSFIELD_LANG=en \
  GRASSFIELD_TRANSLATIONS_DIR="$root/.dev/translations" \
  timeout 60 qs -p "$tmp/cfg" --no-color 2>&1) || true
first=$(grep -m1 -o 'grassfield-lock: published [a-z]* ([a-z]*, beat [0-9]*)' <<<"$out")
if [[ $first == "grassfield-lock: published locking (start, beat 1)" ]] && grep -q "dev-gate: PASS" <<<"$out"; then
  echo "PASS: dev gate restart with a locked marker -> the first published state is locking (beat 1), never unlocked"
else
  echo "FAIL: dev gate restart with a locked marker: first publication '${first:-none}'"
  fail=1
fi
rm -f "$marker"
exit $fail
