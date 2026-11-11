#!/usr/bin/env bash
# Nested (bare command, on a fresh `just nested-up`, unlocked): ADR-0041 step 1, S4, safe mode in this tree's nested session.
# The dev security process never asks systemd (it would read the owner's own unit) and runs neither action: its looks are
# faked with the dev hook `safemode devSet`, and `safemode devPress` presses the notice's buttons through the same refusals.
# Checks: the `safemode` target answers on the security instance only; a faked loop maps one small layer surface
# (`grassfield-safe-mode`) once the looks agree; it follows the light and the dark appearance while it is up (the setting
# through the UI's dev hook, read back from `safemode status`; SAFE_MODE_SHOT=<name> captures each); Try Again (dev:
# suppressed, logged) ends it and the surface goes; a second
# loop brings it back; Log Out (dev: suppressed, logged) leaves it; `lock lock` destroys it before the compositor reports the
# lock, Hyprland reports LOCK on every monitor, no `grassfield-safe-mode` layer exists, and Try Again and Log Out are refused
# while locked (logged); a loop confirmed while locked maps nothing. The nested session stays locked afterwards (no PAM in
# nested): finish with nested-down.sh. Read-only towards the owner's session (pid-selected instances of this tree only).
# PASS/FAIL lines; exit 0 when every check passed, 2 when the nested session is missing or not fresh.
set -u
root=$(git -C "$(dirname "$0")" rev-parse --show-toplevel)
cd "$root"
dev=$root/.dev
# shellcheck source=../../scripts/dev/pidfile.sh
. "$root/scripts/dev/pidfile.sh"
dev_nested_target "$dev" || exit 2
# shellcheck source=nested_ready.sh
. "$root/tests/security/nested_ready.sh"
# Ready first: GF-REF listed and a lock state from the security process (right after nested-up it may not answer yet).
ready_rc=0
nested_ready "$DEV_NESTED_SIG" "$DEV_NESTED_SOCK" "$root/shell/security.qml" "${READY_SECONDS:-60}" || ready_rc=$?
case $ready_rc in
  0) echo "ready: GF-REF listed, lock status $nested_ready_state, after $nested_ready_ms ms" ;;
  2) echo "safe mode nested: $nested_ready_why" >&2; exit 2 ;;
  *) echo "FAIL: safe mode nested ready: $nested_ready_why"; exit 1 ;;
esac
fail=0
pass() { echo "PASS: safe mode nested $*"; }
bad() { echo "FAIL: safe mode nested $*"; fail=1; }

ui=$(dev_live_pid "$dev/shell.pid") || { echo "FAIL: no nested UI"; exit 1; }
sec=$(dev_live_pid "$dev/security.pid") || { echo "FAIL: no nested security process"; exit 1; }
call() { WAYLAND_DISPLAY=$DEV_NESTED_SOCK HYPRLAND_INSTANCE_SIGNATURE=$DEV_NESTED_SIG timeout 5 qs ipc --pid "$1" call "$2" "$3" "${@:4}" 2>&1; }
status() { call "$sec" safemode status; }
field() { jq -r ".$1" <<<"$2" 2>/dev/null; }
layer_mapped() { scripts/nestctl -j layers 2>/dev/null | jq -e '[.. | objects | select(has("namespace")) | .namespace] | index("grassfield-safe-mode") != null' >/dev/null; }
all_locked() { scripts/nestctl -j monitors 2>/dev/null | jq -e 'length > 0 and all(.[]; (.solitaryBlockedBy // []) | type == "array" and index("LOCK") != null)' >/dev/null; }
# wait_for <seconds> <command...>: 0 once the command succeeds, 1 at the deadline.
wait_for() {
  local until=$((SECONDS + $1))
  shift
  while ((SECONDS < until)); do
    "$@" && return 0
    sleep 0.2
  done
  "$@"
}
st_is() { # <jq expression over the status JSON>
  local s
  s=$(status)
  jq -e "$1" <<<"$s" >/dev/null 2>&1
}
log_lines() { grep -c "$1" "$dev/security.log" 2>/dev/null || true; }

# Controls: the target is the security process's alone; the session is fresh (unlocked).
out=$(call "$ui" safemode status)
[[ $out == "Target not found." ]] && pass "the UI instance does not serve safemode ('$out')" || bad "the UI answered safemode status: '$out'"
s=$(status)
jq -e 'type == "object"' <<<"$s" >/dev/null 2>&1 && pass "the security instance answers safemode status: $s" || { bad "safemode status: '$s'"; exit 1; }
[[ $(call "$sec" lock state) == unlocked ]] || { echo "FAIL: safe mode nested needs a fresh, unlocked nested session (lock state: $(call "$sec" lock state))"; exit 2; }
st_is '.confirmed == false and .notice == false and .locked == false' && pass "no safe mode at start, no notice" || bad "start: $(status)"
layer_mapped && bad "a grassfield-safe-mode layer exists before any loop" || pass "no grassfield-safe-mode layer at start"

# A loop (faked): the notice once two looks agree. The focus goes to GF-REF first: the compositor puts a layer surface with no
# output on the focused one, and GF-REF is headless, so it always draws (the nested window's output WAYLAND-1 draws only while
# that window is visible on the owner's screen: a capture of it waits, and an unmapped surface's fade-out never ends there).
timeout 10 scripts/nestctl dispatch "hl.dsp.focus({ monitor = 'GF-REF' })" >/dev/null 2>&1 || true
[[ $(call "$sec" safemode devSet true) == stopped ]] || bad "devSet true did not answer 'stopped'"
wait_for 10 st_is '.confirmed and .shown and .notice' && pass "a faked loop confirms safe mode and makes the notice: $(status)" || bad "no notice after a faked loop: $(status)"
wait_for 5 layer_mapped && pass "the notice is one grassfield-safe-mode layer surface" || bad "no grassfield-safe-mode layer after the notice was made"
n=$(scripts/nestctl -j layers 2>/dev/null | jq '[.. | objects | select(has("namespace")) | select(.namespace == "grassfield-safe-mode")] | length')
[[ $n == 1 ]] && pass "exactly one notice surface ($n)" || bad "notice surfaces: $n"
w=$(scripts/nestctl -j layers 2>/dev/null | jq '[.. | objects | select(has("namespace")) | select(.namespace == "grassfield-safe-mode") | .w] | first')
mw=$(scripts/nestctl -j monitors 2>/dev/null | jq '[.[].width] | min')
[[ $w =~ ^[0-9]+$ && $mw =~ ^[0-9]+$ ]] && ((w < mw / 2)) && pass "the notice is small, not full screen (${w} px wide on a ${mw} px output)" || bad "notice width ${w:-?} on ${mw:-?}"
# Light and dark (the security host binds Appearance.dark to Settings.dark): the appearance is set through the UI's dev hook
# `controlcenter appearance` (the persisted setting both processes read), and the alert must follow it while it is up,
# read back from `safemode status` (`dark`). SAFE_MODE_SHOT=<name>: a capture of the output the notice is on per appearance
# (scripts/dev/shot.sh, .dev/shots/<name>-light.png and -dark.png). The setting goes back to what it was.
shot() { # <name>
  local on
  [[ -n ${SAFE_MODE_SHOT:-} ]] || return 0
  on=$(scripts/nestctl -j layers 2>/dev/null | jq -r 'to_entries[] | select([.value | .. | objects | select(has("namespace")) | .namespace] | index("grassfield-safe-mode") != null) | .key' | head -1)
  sleep 1 # the alert's new frames
  timeout 20 scripts/dev/shot.sh "$1" "$on" >/dev/null && echo "shot: .dev/shots/$1.png (output $on)" || echo "shot: none (output '${on}')"
}
was=$(tests/visual/ipc.sh controlcenter state 2>/dev/null | jq -r '.appearance // empty' 2>/dev/null)
for look in light dark; do
  tests/visual/ipc.sh controlcenter appearance "$look" >/dev/null 2>&1
  want=$([[ $look == dark ]] && echo true || echo false)
  wait_for 10 st_is ".dark == $want and .shown and .notice" && pass "$look appearance: the alert follows it while it is up" || bad "$look appearance: $(status)"
  wait_for 5 layer_mapped && pass "$look appearance: still one notice surface" || bad "$look appearance: no notice surface"
  shot "${SAFE_MODE_SHOT:-safe-mode}-$look"
done
[[ $was =~ ^(auto|light|dark)$ ]] && tests/visual/ipc.sh controlcenter appearance "$was" >/dev/null 2>&1

# Try Again (dev: suppressed) ends safe mode; the surface goes.
before=$(log_lines "dev session, suppressed Try Again")
[[ $(call "$sec" safemode devPress tryAgain) == ok ]] && pass "Try Again from the notice answers ok" || bad "devPress tryAgain while shown"
wait_for 5 st_is '.confirmed == false and .notice == false' && pass "Try Again ends safe mode and the notice" || bad "after Try Again: $(status)"
wait_for 5 bash -c '! scripts/nestctl -j layers 2>/dev/null | jq -e "[.. | objects | select(has(\"namespace\")) | .namespace] | index(\"grassfield-safe-mode\") != null" >/dev/null' && pass "the notice surface is gone" || bad "the notice surface stayed after Try Again"
(($(log_lines "dev session, suppressed Try Again") == before + 1)) && pass "the dev session ran nothing for Try Again (suppressed, logged once)" || bad "suppressed Try Again lines: $(log_lines 'dev session, suppressed Try Again') (before $before)"

# A second loop brings it back; Log Out (dev: suppressed) leaves it.
call "$sec" safemode devSet true >/dev/null
wait_for 10 st_is '.shown and .notice' && pass "a second loop brings the notice back" || bad "second loop: $(status)"
before=$(log_lines "dev session, suppressed grassfield-session-end logout")
[[ $(call "$sec" safemode devPress logOut) == ok ]] && pass "Log Out from the notice answers ok" || bad "devPress logOut while shown"
(($(log_lines "dev session, suppressed grassfield-session-end logout") == before + 1)) && pass "the dev session ran nothing for Log Out (suppressed, logged once)" || bad "suppressed Log Out lines"
st_is '.shown and .notice' && pass "the notice stays after a Log Out that did not end the session" || bad "after Log Out: $(status)"

# The lock always wins.
out=$(call "$sec" lock lock)
[[ $out == ok || $out == already-locked ]] && pass "lock lock: $out" || bad "lock lock: '$out'"
wait_for 10 st_is '.locked and .shown == false and .notice == false' && pass "locked: the notice is destroyed, safe mode still known: $(status)" || bad "locked: $(status)"
wait_for 10 all_locked && pass "Hyprland reports LOCK on every monitor" || bad "monitors not all LOCK: $(scripts/nestctl -j monitors | jq -c '[.[] | {name, solitaryBlockedBy}]')"
layer_mapped && bad "a grassfield-safe-mode layer exists while locked" || pass "no grassfield-safe-mode layer while locked"
[[ $(call "$sec" safemode devPress tryAgain) == refused ]] && pass "Try Again refused while locked" || bad "Try Again while locked was not refused"
[[ $(call "$sec" safemode devPress logOut) == refused ]] && pass "Log Out refused while locked" || bad "Log Out while locked was not refused"
grep -q "grassfield-safe-mode: Try Again refused (locked)" "$dev/security.log" && pass "the refusal is logged with its reason" || bad "no 'Try Again refused (locked)' line"
call "$sec" safemode devSet false >/dev/null
wait_for 10 st_is '.confirmed == false' || bad "devSet false while locked: $(status)"
call "$sec" safemode devSet true >/dev/null
wait_for 10 st_is '.confirmed and .notice == false and .shown == false' && pass "a loop confirmed while locked maps nothing" || bad "loop while locked: $(status)"
layer_mapped && bad "a notice surface appeared under the lock" || pass "still no notice surface under the lock"
all_locked && pass "still LOCK on every monitor" || bad "the lock changed"
grep -q "grassfield-safe-mode" "$dev/shell.log" && bad "the UI logged grassfield-safe-mode lines" || pass "the UI log has no safe-mode line (it runs in the security process)"
echo "safe mode nested: the session stays locked (no PAM in nested); finish with scripts/dev/nested-down.sh"
exit "$fail"
