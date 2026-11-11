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
#   shows-with-the-displays-off  SafeModeModel.shown ignores the displays idle turned off (the opus review of a0df9c3e, MINOR-2)
#   no-guard                   a press at once after the notice appears acts (the wake key, a repeated Return: MINOR-2)
#   not-lazy                   the notice's LazyLoader always active
#   one-look                   one look confirms safe mode
# Then the real-session paths (MINOR-3), against stubs only: the look's own shell script taken from SafeMode.qml (a plain
# file counts, a FIFO, a directory, a link, a dangling link, an empty path, a missing file or a file in a linked directory
# do not; its answer parses), and the controller outside a dev session (safe_mode.d/probe_real.qml) with its three commands
# pointed at stubs in a copy: the looks, Try Again failing, hanging past the action guard (shortened) and working, Log Out
# with apps open and with the session not ended. No copy that still names a real systemctl or /usr/lib/grassfield runs.
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
mutant shows-over-the-lock SafeModeModel.js "return isConfirmed === true && locked === false && sheetUp === false && displaysOff === false;" "return isConfirmed === true && sheetUp === false && displaysOff === false;"
mutant try-again-while-locked SafeMode.qml '        if (!Model.canAct(root.shown, root.busy, root.armed)) {\n            console.warn("grassfield-safe-mode: Try Again refused' '        if (root.busy) {\n            console.warn("grassfield-safe-mode: Try Again refused'
mutant log-out-while-locked SafeMode.qml '        if (!Model.canAct(root.shown, root.busy, root.armed)) {\n            console.warn("grassfield-safe-mode: Log Out refused' '        if (root.busy) {\n            console.warn("grassfield-safe-mode: Log Out refused'
mutant shows-over-a-sheet SafeModeModel.js "return isConfirmed === true && locked === false && sheetUp === false && displaysOff === false;" "return isConfirmed === true && locked === false && displaysOff === false;"
mutant shows-with-the-displays-off SafeModeModel.js "return isConfirmed === true && locked === false && sheetUp === false && displaysOff === false;" "return isConfirmed === true && locked === false && sheetUp === false;"
mutant no-guard SafeModeModel.js "return isShown === true && busy === false && armed === true;" "return isShown === true && busy === false;"
mutant not-lazy SafeMode.qml "        active: root.shown\n" "        active: true\n"
mutant one-look SafeModeModel.js "var SETTLE_LOOKS = 2;" "var SETTLE_LOOKS = 1;"

# ---- The real-session paths (the opus review of a0df9c3e, MINOR-3), against stubs only ----
# The look's own shell script, taken from SafeMode.qml as it ships: the flag counts only as a plain file that is not a link, in
# a directory that is not a link (as the counter and `grassfield-shell-failed --try-again` refuse a linked runtime directory);
# a FIFO, a directory, a link, a dangling link, an empty path or a missing file count as no flag. Its systemctl is a stub.
stubs=$tmp/stubs
mkdir -p "$stubs"
cat >"$stubs/systemctl" <<SH
#!/bin/sh
echo "systemctl \$*" >>"$stubs/log"
set -- \$(cat "$stubs/state" 2>/dev/null)
printf 'ActiveState=%s\nSubState=%s\nResult=%s\n' "\${1:-inactive}" "\${2:-dead}" "\${3:-success}"
SH
chmod +x "$stubs/systemctl"
script=$(python3 -I - "$root/shell/security/safemode/SafeMode.qml" "$stubs/systemctl" <<'PY'
import json, re, sys
src = open(sys.argv[1]).read()
m = re.search(r'command: \["/usr/bin/timeout", "-k", "1", "5", "/usr/bin/sh", "-c", ("(?:[^"\\]|\\.)*"), "grassfield-safe-mode", root\.markerPath\]', src)
if not m:
    sys.exit("no look command in SafeMode.qml")
script = json.loads(m.group(1))
if script.count("/usr/bin/systemctl") != 1:
    sys.exit("the look names systemctl other than once")
print(script.replace("/usr/bin/systemctl", sys.argv[2]))
PY
) || { echo "FAIL: safe mode look: cannot read its command from SafeMode.qml"; exit 1; }
if grep -q "/usr/bin/systemctl" <<<"$script"; then echo "FAIL: safe mode look: the test copy would run a real systemctl"; exit 1; fi
f=$tmp/flags
mkdir -p "$f/real/grassfield" "$f/elsewhere/grassfield"
printf 'loop 1 3\n' >"$f/real/grassfield/shell-safe-mode"
mkfifo "$f/real/grassfield/fifo"
mkdir "$f/real/grassfield/dir"
ln -s "$f/real/grassfield/shell-safe-mode" "$f/real/grassfield/link"
ln -s "$f/real/grassfield/none" "$f/real/grassfield/dangling"
printf 'loop 1 3\n' >"$f/elsewhere/grassfield/shell-safe-mode"
ln -s "$f/elsewhere/grassfield" "$f/linked"
for case_ in "1|$f/real/grassfield/shell-safe-mode|a plain file" "0|$f/real/grassfield/missing|a missing file" \
  "0|$f/real/grassfield/fifo|a FIFO (never opened)" "0|$f/real/grassfield/dir|a directory" "0|$f/real/grassfield/link|a link to a plain file" \
  "0|$f/real/grassfield/dangling|a dangling link" "0||an empty path (no XDG_RUNTIME_DIR)" "0|$f/linked/shell-safe-mode|a plain file in a linked directory"; do
  IFS='|' read -r want path what <<<"$case_"
  got=$(timeout 5 bash -c 'sh -c "$1" grassfield-safe-mode "$2" 2>/dev/null | sed -n "s/^marker=//p"' _ "$script" "$path")
  [[ $got == "$want" ]] && echo "PASS: safe mode look: $what reads marker=$want" || { echo "FAIL: safe mode look: $what reads marker='$got' (want $want)"; fail=1; }
done
out=$(sh -c "$script" grassfield-safe-mode "$f/real/grassfield/shell-safe-mode" 2>/dev/null)
python3 -I - "$root/shell/security/safemode/SafeModeModel.js" "$out" <<'PY' && echo "PASS: safe mode look: its answer parses as SafeModeModel reads it (marker, ActiveState, SubState, Result)" || { echo "FAIL: safe mode look: answer '$out'"; fail=1; }
import sys
out = sys.argv[2].strip().split("\n")
keys = [l.split("=", 1)[0] for l in out]
sys.exit(0 if sorted(keys) == ["ActiveState", "Result", "SubState", "marker"] else 1)
PY
grep -qx "systemctl --user show --property=ActiveState --property=SubState --property=Result grassfield-shell.service" "$stubs/log" && echo "PASS: safe mode look: it asks the unit's ActiveState, SubState and Result, as the user" || { echo "FAIL: safe mode look: systemctl was asked '$(head -1 "$stubs/log")'"; fail=1; }

# The controller outside a dev session (probe_real.qml): its three commands point at stubs in a copy (and the action guard is
# shortened to 1.5 s, the looks to 0.3 s); the copy is refused if it still names a real systemctl or /usr/lib/grassfield.
real=$tmp/real
mkdir -p "$real/runtime/grassfield" "$real/home" "$real/cfg/security/safemode"
chmod 700 "$real/runtime" "$real/runtime/grassfield"
: >"$stubs/log"
printf 'inactive dead success\n' >"$stubs/state"
printf 'loop 1 3\n' >"$real/runtime/grassfield/shell-safe-mode"
cat >"$stubs/shell-failed" <<SH
#!/bin/sh
echo "shell-failed \$*" >>"$stubs/log"
case \$(cat "$stubs/helper" 2>/dev/null) in
  ok) rm -f "$real/runtime/grassfield/shell-safe-mode"; printf 'active running success\n' >"$stubs/state"; exit 0 ;;
  slow) sleep 3; exit 0 ;;
  *) exit 1 ;;
esac
SH
cat >"$stubs/session-end" <<SH
#!/bin/sh
echo "session-end \$*" >>"$stubs/log"
exit \$(cat "$stubs/logout-rc" 2>/dev/null || echo 1)
SH
chmod +x "$stubs/shell-failed" "$stubs/session-end"
sed -e "s#/usr/bin/systemctl#$stubs/systemctl#g" -e "s#/usr/lib/grassfield/grassfield-shell-failed#$stubs/shell-failed#g" \
  -e "s#/usr/lib/grassfield/grassfield-session-end#$stubs/session-end#g" "$root/shell/security/safemode/SafeMode.qml" >"$real/cfg/security/safemode/SafeMode.qml"
sed -e "s#^var ACTION_GUARD_MS = 340000;#var ACTION_GUARD_MS = 1500;#" -e "s#^var LOOK_IDLE_MS = 5000;#var LOOK_IDLE_MS = 300;#" \
  -e "s#^var LOOK_WATCH_MS = 2000;#var LOOK_WATCH_MS = 300;#" "$root/shell/security/safemode/SafeModeModel.js" >"$real/cfg/security/safemode/SafeModeModel.js"
cp "$root/shell/security/safemode/qmldir" "$real/cfg/security/safemode/"
cp tests/security/safe_mode.d/SafeModeNotice.qml "$real/cfg/security/safemode/SafeModeNotice.qml"
printf 'import QtQuick\nItem {}\n' >"$real/cfg/security/safemode/SafeModeCard.qml"
ln -s "$root/shell/lib" "$real/cfg/lib"
cp tests/security/safe_mode.d/probe_real.qml "$real/cfg/shell.qml"
if grep -qE "/usr/bin/systemctl|/usr/lib/grassfield" "$real/cfg/security/safemode/SafeMode.qml" ||
  ! grep -q "ACTION_GUARD_MS = 1500;" "$real/cfg/security/safemode/SafeModeModel.js"; then
  echo "FAIL: safe mode real paths: the copy still names a real command, or its guard is not shortened"
  exit 1
fi
env -u WAYLAND_DISPLAY -u HYPRLAND_INSTANCE_SIGNATURE -u DISPLAY -u DBUS_SESSION_BUS_ADDRESS -u GRASSFIELD_SESSION -u GRASSFIELD_DEV \
  SAFE_MODE_STUBS="$stubs" HOME="$real/home" XDG_RUNTIME_DIR="$real/runtime" XDG_CACHE_HOME="$real/home/.cache" \
  QT_QPA_PLATFORM=offscreen QML_IMPORT_PATH="$root/ui:$root/.dev/build/qml" GRASSFIELD_LANG=en \
  timeout 90 qs -p "$real/cfg" --no-color >"$real/log" 2>&1 || true
out=$(grep -m1 -E "safe-mode-real: (PASS|FAIL)" "$real/log" || echo "safe-mode-real: no verdict")
if [[ $out == *"safe-mode-real: PASS"* ]]; then
  echo "PASS: safe mode real paths: ${out#*safe-mode-real: PASS }"
else
  echo "FAIL: safe mode real paths: $out"
  sed -n '1,60p' "$real/log"
  fail=1
fi
python3 -I tests/ci/qml_warnings.py <"$real/log" && echo "PASS: safe mode real paths: no QML runtime error" || { echo "FAIL: safe mode real paths: QML runtime errors"; fail=1; }
grep -qx "systemctl --user show --property=ActiveState --property=SubState --property=Result grassfield-shell.service" "$stubs/log" && echo "PASS: safe mode real paths: the controller's look asked the stub the unit's state" || { echo "FAIL: safe mode real paths: no look reached the stub"; fail=1; }
[[ $(grep -cx "shell-failed --try-again" "$stubs/log") == 3 && $(grep -cx "session-end logout" "$stubs/log") == 2 ]] && echo "PASS: safe mode real paths: Try Again ran the helper with --try-again (3 times), Log Out the logout path (2 times), nothing else" || { echo "FAIL: safe mode real paths: the stubs were asked: $(grep -v '^systemctl' "$stubs/log" | sort | uniq -c | tr '\n' ' ')"; fail=1; }
[[ $(grep -cvE "^(systemctl --user show --property=ActiveState --property=SubState --property=Result grassfield-shell.service|shell-failed --try-again|session-end logout)$" "$stubs/log") == 0 ]] && echo "PASS: safe mode real paths: no other command reached a stub" || { echo "FAIL: safe mode real paths: other calls"; fail=1; }
grep -q "grassfield-safe-mode: tryAgain did not finish (exit -1)" "$real/log" && echo "PASS: safe mode real paths: the action guard's end is logged (exit -1)" || { echo "FAIL: safe mode real paths: no guard line"; fail=1; }
exit "$fail"
