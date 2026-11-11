#!/usr/bin/env bash
# ADR-0041 step 1, S4 (safe mode), offscreen: tests/security/safe_mode.d/probe.qml runs the REAL controller
# (shell/security/safemode/SafeMode.qml with SafeModeModel.js) under Quickshell in a dev session, with a stand-in for the
# notice's window (safe_mode.d/SafeModeNotice.qml: offscreen has no layer-shell backend), the probe binding the lock and the
# sheets as the host does: the notice exists only after two looks that say safe mode, only while unlocked and with no sheet
# up; the lock or a sheet destroys it at once and refuses Try Again and Log Out; it comes back after the unlock; the
# notice's buttons reach the actions; Try Again ends safe mode; an action under way refuses another. Then the same probe
# against copies with one rule removed each (mutants); each must make it FAIL:
#   shows-over-the-lock        SafeModeModel.shown ignores the lock
#   try-again-while-locked     Try Again's refusal removed
#   log-out-while-locked       Log Out's refusal removed
#   shows-over-a-sheet         SafeModeModel.shown ignores the sheets
#   not-lazy                   the notice's LazyLoader always active
#   one-look                   one look confirms safe mode
# The dev session never asks systemd and runs no action (the owner's machine is never touched); XDG_RUNTIME_DIR is a scratch
# directory under .dev/. No compositor, no bus, no lock. Plain shell test: PASS/FAIL lines, non-zero on failure.
set -euo pipefail
root=$(git -C "$(dirname "$0")" rev-parse --show-toplevel)
cd "$root"
unset QT_QPA_PLATFORMTHEME
command -v qs >/dev/null || { echo "SKIP: safe_mode needs Quickshell (qs)"; exit 0; }
mkdir -p "$root/.dev"
tmp=$(mktemp -d "$root/.dev/safe-mode.XXXXXX")
trap 'rm -rf "$tmp"' EXIT
fail=0

# A config directory: the probe as shell.qml, a copy of the safe-mode module (the stand-in notice in place of the window)
# with at most one mutant, and the real shell/lib (RunMode.js, which SafeMode.qml imports by its relative path).
tree() { # <dir> [<file> <find> <replace>]
  local dir=$1
  mkdir -p "$dir/runtime" "$dir/home" "$dir/cfg/security/safemode"
  chmod 700 "$dir/runtime"
  cp "$root/shell/security/safemode/SafeMode.qml" "$root/shell/security/safemode/SafeModeModel.js" \
    "$root/shell/security/safemode/qmldir" "$dir/cfg/security/safemode/"
  cp tests/security/safe_mode.d/SafeModeNotice.qml "$dir/cfg/security/safemode/SafeModeNotice.qml"
  # The card is the window's content only: not needed without the window (the qmldir names it; an empty stand-in keeps it).
  printf 'import QtQuick\nItem {}\n' >"$dir/cfg/security/safemode/SafeModeCard.qml"
  ln -s "$root/shell/lib" "$dir/cfg/lib"
  cp tests/security/safe_mode.d/probe.qml "$dir/cfg/shell.qml"
  if [[ $# -ge 4 ]]; then
    python3 -I - "$dir/cfg/security/safemode/$2" "$3" "$4" <<'PY' || return 3
import sys
path, old, new = sys.argv[1:4]
old, new = old.replace("\\n", "\n"), new.replace("\\n", "\n")
text = open(path).read()
if text.count(old) != 1:
    sys.exit(3)
open(path, "w").write(text.replace(old, new))
PY
  fi
}

run() { # <dir>: prints the probe's verdict line (the whole log in <dir>/log)
  local dir=$1
  env -u WAYLAND_DISPLAY -u HYPRLAND_INSTANCE_SIGNATURE -u DISPLAY -u DBUS_SESSION_BUS_ADDRESS -u GRASSFIELD_SESSION \
    GRASSFIELD_DEV=1 HOME="$dir/home" XDG_RUNTIME_DIR="$dir/runtime" XDG_CACHE_HOME="$dir/home/.cache" \
    QT_QPA_PLATFORM=offscreen QML_IMPORT_PATH="$root/ui:$root/.dev/build/qml" GRASSFIELD_LANG=en \
    timeout 60 qs -p "$dir/cfg" --no-color >"$dir/log" 2>&1 || true
  grep -m1 -E "safe-mode: (PASS|FAIL)" "$dir/log" || echo "safe-mode: no verdict"
}

tree "$tmp/control"
out=$(run "$tmp/control")
if [[ $out == *"safe-mode: PASS"* ]]; then
  echo "PASS: safe mode controller: ${out#*safe-mode: PASS }"
else
  echo "FAIL: safe mode controller: $out"
  sed -n '1,60p' "$tmp/control/log"
  fail=1
fi
# Gate Q2: no QML runtime error of a product file in the run.
python3 -I tests/ci/qml_warnings.py <"$tmp/control/log" && echo "PASS: safe mode controller: no QML runtime error" || { echo "FAIL: safe mode controller: QML runtime errors"; fail=1; }
grep -q "grassfield-safe-mode: dev session, suppressed Try Again" "$tmp/control/log" && echo "PASS: safe mode controller: Try Again is suppressed in a dev session (logged)" || { echo "FAIL: safe mode controller: no suppressed Try Again line"; fail=1; }
grep -q "grassfield-safe-mode: dev session, suppressed grassfield-session-end logout" "$tmp/control/log" && echo "PASS: safe mode controller: Log Out is suppressed in a dev session (logged)" || { echo "FAIL: safe mode controller: no suppressed Log Out line"; fail=1; }
grep -q "grassfield-safe-mode: Try Again refused (locked)" "$tmp/control/log" && echo "PASS: safe mode controller: Try Again while locked is refused and logged" || { echo "FAIL: safe mode controller: no refusal line while locked"; fail=1; }

mutant() { # <name> <file> <find> <replace>
  local name=$1 dir=$tmp/$1 out
  shift
  tree "$dir" "$@" || { echo "FAIL: safe mode mutant $name does not apply (stale)"; fail=1; return; }
  out=$(run "$dir")
  if [[ $out == *"safe-mode: FAIL"* ]]; then
    echo "PASS: safe mode mutant $name is caught (${out#*safe-mode: FAIL: })"
  else
    echo "FAIL: safe mode mutant $name is not caught: $out"
    fail=1
  fi
  rm -rf "$dir"
}
mutant shows-over-the-lock SafeModeModel.js "return isConfirmed === true && locked === false && sheetUp === false;" "return isConfirmed === true && sheetUp === false;"
mutant try-again-while-locked SafeMode.qml '        if (!Model.canAct(root.shown, root.busy)) {\n            console.warn("grassfield-safe-mode: Try Again refused' '        if (root.busy) {\n            console.warn("grassfield-safe-mode: Try Again refused'
mutant log-out-while-locked SafeMode.qml '        if (!Model.canAct(root.shown, root.busy)) {\n            console.warn("grassfield-safe-mode: Log Out refused' '        if (root.busy) {\n            console.warn("grassfield-safe-mode: Log Out refused'
mutant shows-over-a-sheet SafeModeModel.js "return isConfirmed === true && locked === false && sheetUp === false;" "return isConfirmed === true && locked === false;"
mutant not-lazy SafeMode.qml "        active: root.shown\n" "        active: true\n"
mutant one-look SafeModeModel.js "var SETTLE_LOOKS = 2;" "var SETTLE_LOOKS = 1;"
exit "$fail"
