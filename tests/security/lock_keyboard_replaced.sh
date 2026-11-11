#!/usr/bin/env bash
# Nested scenario (integrator decision 2026-10-24): the Grassfield lock screen keeps its keys when the session's only
# keyboard is replaced (a desktop's Bluetooth keyboard reconnecting at resume, on the lock screen). Never targets the
# owner's session. Never presses Return: letters and Escape only (Escape clears the field and never submits), and the
# dev shell suppresses PAM anyway, so no password ever reaches PAM.
#
# The condition: a nested session with no keyboard device of its own (the parent seat had no keyboard when
# scripts/dev/nested-up.sh started it). Every wtype burst is then a new keyboard device after the previous one went away,
# the seat loses its keyboard capability in between, and clients re-create their wl_keyboard; Quickshell then ignores
# the keys of the re-created one until it gets a new wl_keyboard.leave and enter, which grassfield-compositor announces
# again before the first key of the new device, to the same session-lock surface (docs/specs/compositor.md "Keyboard
# focus before every key"). Hyprland 0.56.2 keeps a disabled keyboard (device `enabled = false`) in the seat's
# capabilities, so the condition cannot be produced through scripts/nestctl: without it the scenario is SKIPPED (exit 3),
# as it is when grassfield-compositor is not loaded (the fix under test is its focus announce).
#
# Steps: a foot probe window gets a control word while unlocked; `lock lock`; then six bursts of ONE key each, each from a
# new keyboard device, so that every check is about the first key of a burst (the key a late announce loses): "x" (the
# field fills), Escape (it empties), "y", Escape, "z", Escape. After each: the lock's field state (`lock devLockView`:
# filled or empty, never the text), the lock state `locked`, Hyprland's LOCK on every monitor, nothing typed in the foot
# window, no PAM attempt. Without the announce the second burst and every later one are lost (the field stays filled
# after the first Escape); with an announce made in the key path, each burst's only key is lost.
#
# Usage: tests/security/lock_keyboard_replaced.sh   (bare; NESTED only, GRASSFIELD_DEV=1 shell from nested-up.sh)
# The nested session stays LOCKED afterwards (only a real password opens it, and PAM is suppressed): finish with
# scripts/dev/nested-down.sh. Exit: 0 PASS, 1 FAIL, 2 environment, 3 SKIPPED (the session has a keyboard of its own, or
# grassfield-compositor is not loaded), 4 stopped for safety.
set -uo pipefail

root=$(git -C "$(dirname "$0")" rev-parse --show-toplevel)
# GRASSFIELD_MIGRATED=1: the nested session runs the packaged form of the UI tree (scripts/dev/shell-run.sh --migrated,
# ADR-0056): both instances are addressed by the REAL path of the stamped tree (readlink -f .dev/migrated), as they were started.
ui_dir=$root/shell; sec_qml=$root/shell/security.qml
[[ ${GRASSFIELD_MIGRATED:-0} == 1 ]] && { ui_dir=$(readlink -f "$root/.dev/migrated")/shell; sec_qml=$ui_dir/security.qml; }
dev=$root/.dev
# shellcheck source=../../scripts/dev/pidfile.sh
. "$root/scripts/dev/pidfile.sh"
dev_require_host lock_keyboard_replaced
dev_nested_target "$dev" || exit 2
sig=$DEV_NESTED_SIG
sock=$DEV_NESTED_SOCK
main=$(cat "$dev/main.instance" 2>/dev/null || true)
[[ $sig != "$main" && $sig != "${HYPRLAND_INSTANCE_SIGNATURE:-}" && $sock != "${WAYLAND_DISPLAY:-}" ]] \
  || { echo "lock_keyboard_replaced: refusing the main instance" >&2; exit 2; }
for tool in foot jq wtype; do
  command -v "$tool" >/dev/null || { echo "lock_keyboard_replaced: $tool is not installed" >&2; exit 2; }
done

typed=$dev/lock-keyboard-typed.txt
status=0
nested() { env WAYLAND_DISPLAY="$sock" HYPRLAND_INSTANCE_SIGNATURE="$sig" "$@"; }
# The lock lives in the security process since ADR-0041 step 1, S2 (shell/security.qml, started by scripts/dev/shell-run.sh).
ipc() { nested qs ipc -p "$sec_qml" call "$@" 2>/dev/null; }
nestctl() { timeout 10 "$root/scripts/nestctl" "$@"; }
pass() { echo "PASS $*"; }
fail() { echo "FAIL $*"; status=1; }
compositor_locked() {
  nestctl -j monitors 2>/dev/null | jq -e 'length > 0 and all(.[]; (.solitaryBlockedBy // []) | index("LOCK") != null)' >/dev/null
}
view_field() { ipc lock devLockView | jq -r '.field // "?"' 2>/dev/null; }

# PAM: every attempt this run could cause, counted against a baseline (tests/security/pam_audit.sh). Any new submit stops
# the run and the nested session at once.
# shellcheck source=pam_audit.sh
. "$root/tests/security/pam_audit.sh"
read -r _ pam_base_submits pam_base_suppressed < <(pam_counts)
assert_no_pam() { # <when>
  local n s x
  read -r n s x < <(pam_counts)
  if ((s > pam_base_submits || x > pam_base_suppressed)); then
    echo "ABORT ($1): a PAM submit since the run started; stopping the nested session" >&2
    "$root/scripts/dev/nested-down.sh" >&2 2>&1 || true
    exit 4
  fi
}
# The only typing paths: letters (and digits) only, or Escape alone. Each wtype run is a new keyboard device.
type_letters() { # <word>
  [[ $# -eq 1 && $1 =~ ^[a-z0-9]+$ ]] || { echo "FATAL type_letters: refusing '$*'" >&2; exit 4; }
  nested wtype -s 150 -d 15 "$1"
}
press_escape() { nested wtype -s 150 -k Escape; }

own=$(nestctl -j devices 2>/dev/null | jq -r '[.keyboards[]? | select(.name | test("virtual") | not)] | length')
if [[ $own != 0 ]]; then
  echo "SKIP lock_keyboard_replaced: the nested session has ${own:-?} keyboard device(s) of its own; the scenario needs a session whose only keyboards come and go (the parent seat had no keyboard when nested-up.sh started it)"
  exit 3
fi
# What this scenario proves is grassfield-compositor's focus announce (docs/specs/compositor.md "Keyboard focus before every
# key"). Without the plugin the documented limit applies (docs/specs/security.md, known limitations): every burst after the
# first is lost, so the Escape bursts leave the field filled and the letter bursts pass only because it is still filled.
# The integrator's nested run of S2 (e1a3ff4c) failed exactly so, with "nested-up: ... plugin none" (no compositor/build in
# the checkout), as main 8b04383c did: a SKIP, not a FAIL, so that it is not read as a lock regression.
if ! nestctl -j grassfield 2>/dev/null | jq -e '.features | type == "array"' >/dev/null 2>&1; then
  echo "SKIP lock_keyboard_replaced: grassfield-compositor is not loaded in the nested session (nested-up.sh printed 'plugin none'); the lock's keys after a replaced keyboard depend on its focus announce: build it (just plugin-build), start the nested session again, run this again: NOT VERIFIED"
  exit 3
fi
[[ $(ipc lock status) != refused ]] || { echo "lock_keyboard_replaced: the shell's dev hooks are refused (not a GRASSFIELD_DEV session)" >&2; exit 2; }
assert_no_pam "start"

# Setup: a foot probe window in raw mode; a control word reaches it while unlocked.
: >"$typed"
"$root/scripts/dev/pointer.sh" output GF-REF abs 960 540 >/dev/null
nested setsid "$root/scripts/dev/isolated.sh" foot --app-id=gf-lock-kbd-probe -- sh -c 'stty raw -echo; exec cat >"$1"' sh "$typed" >/dev/null 2>&1 </dev/null &
foot_pid=$!
addr=""
for _ in $(seq 1 40); do
  addr=$(nestctl -j clients 2>/dev/null | jq -r '.[] | select(.class == "gf-lock-kbd-probe") | .address' | head -n 1)
  [[ -n $addr ]] && break
  sleep 0.25
done
[[ -n $addr ]] || { echo "lock_keyboard_replaced: the foot probe window did not appear" >&2; kill "$foot_pid" 2>/dev/null; exit 2; }
nestctl dispatch "hl.dsp.focus({ window = \"address:$addr\" })" >/dev/null 2>&1
sleep 0.5
type_letters control
sleep 0.7
if grep -q control "$typed"; then pass "setup: typing reaches the foot window while unlocked (control)"; else fail "setup: the control word did not reach foot; the leak check is meaningless"; fi

echo "lock lock -> $(ipc lock lock)"
locked=""
for _ in $(seq 1 40); do
  locked=$(ipc lock status)
  [[ $locked == locked ]] && compositor_locked && break
  sleep 0.25
done
if [[ $locked == locked ]] && compositor_locked; then pass "lock: the shell is locked and Hyprland reports LOCK"; else fail "lock: not locked ($locked)"; fi

# The bursts. Each check waits up to 2 s for the field state (the shell answers over IPC).
burst() { # <label> <expected field> <command...>
  local label=$1 want=$2 got="" i
  shift 2
  "$@"
  for i in $(seq 1 8); do
    got=$(view_field)
    [[ $got == "$want" ]] && break
    sleep 0.25
  done
  assert_no_pam "$label"
  local leak=no
  [[ $(tr -d '\r\n' <"$typed") == control ]] || leak=yes
  local state
  state=$(ipc lock status)
  if [[ $got == "$want" && $leak == no && $state == locked ]] && compositor_locked; then
    pass "$label: the lock field is $got, nothing reached the foot window, still locked"
  else
    fail "$label: lock field $got (want $want), foot got '$(tr -d '\r' <"$typed" | cat -v)', lock state $state, Hyprland LOCK $(compositor_locked && echo yes || echo no)"
  fi
}
burst "burst 1 (x, a new keyboard device)" filled type_letters x
burst "burst 2 (Escape, the keyboard replaced)" empty press_escape
burst "burst 3 (y, replaced again)" filled type_letters y
burst "burst 4 (Escape, replaced again)" empty press_escape
burst "burst 5 (z, replaced again)" filled type_letters z
burst "burst 6 (Escape, replaced again)" empty press_escape

kill "$foot_pid" 2>/dev/null
if ((status == 0)); then echo "lock_keyboard_replaced: PASS"; else echo "lock_keyboard_replaced: FAIL"; fi
echo "lock_keyboard_replaced: the nested session stays locked; finish with scripts/dev/nested-down.sh"
exit "$status"
