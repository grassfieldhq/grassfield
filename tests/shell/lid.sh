#!/usr/bin/env bash
# Lid and clamshell (macOS model): packaging/bin/grassfield-lid against fake /proc and /sys trees and a fake hyprctl.
#  * every lid close asks the shell to lock with `lock lid` (D-4); the shell decides: it does not lock in clamshell mode
#    (shell/security/LockMachine.js lidShouldLock, tests/security/tst_lockmachine.qml), so the script never decides;
#  * lid closed, no external display: the lock request, the laptop panel is left alone;
#  * lid closed with an external display: the lock request too (the shell answers "docked"), and the laptop panel is
#    switched off (the computer keeps running);
#  * the lid switch is bound once (system.lua), not in bindings.lua;
#  * lid opened, or the external display unplugged while closed: the user's monitor configuration is applied again;
#  * every call is idempotent.
set -euo pipefail
root=$(git -C "$(dirname "$0")" rev-parse --show-toplevel)
tmp=$(mktemp -d "${GRASSFIELD_TEST_TMP:-${TMPDIR:-/tmp}}/lid.XXXXXX")
trap 'rm -rf "$tmp"' EXIT
fail=0
check() { if "$@"; then echo "PASS: $desc"; else echo "FAIL: $desc"; fail=1; fi; }

mkdir -p "$tmp/bin" "$tmp/proc/LID0" "$tmp/drm/card1-eDP-1" "$tmp/drm/card1-DP-3" "$tmp/drm/card1-HDMI-A-1" "$tmp/run"
printf '#!/bin/sh\necho "hyprctl $*" >>"$FAKE_DIR/calls.log"\n' >"$tmp/bin/hyprctl"
# The shell's answer to `lock lid` (FAKE_LOCK: ok by default, "fail" = no instance, any other text is printed).
printf '#!/bin/sh\necho "lock" >>"$FAKE_DIR/calls.log"\n[ "${FAKE_LOCK:-ok}" = fail ] && exit 1\necho "${FAKE_LOCK:-ok}"\n' >"$tmp/bin/lock"
# The omarchy-shell stand-in (restart + lock) that grassfield-lid falls back to when the shell does not answer.
printf '#!/bin/sh\necho "fallback $*" >>"$FAKE_DIR/calls.log"\n' >"$tmp/bin/fallback"
chmod +x "$tmp/bin/hyprctl" "$tmp/bin/lock" "$tmp/bin/fallback"

setup() { # setup <lid open|closed> <DP-3 connected|disconnected>
  printf 'state:      %s\n' "$1" >"$tmp/proc/LID0/state"
  printf '%s\n' connected >"$tmp/drm/card1-eDP-1/status"
  printf '%s\n' "$2" >"$tmp/drm/card1-DP-3/status"
  printf '%s\n' disconnected >"$tmp/drm/card1-HDMI-A-1/status"
}
# A dev session: grassfield-lid honours its test hooks only there (ADR-0019 dev plumbing; the real-session case is
# tests/security/lock_request_env.sh).
lid() {
  env -u GRASSFIELD_SESSION GRASSFIELD_DEV=1 \
  FAKE_DIR=$tmp PATH="$tmp/bin:$PATH" XDG_RUNTIME_DIR=$tmp/run GRASSFIELD_LID_PROC=$tmp/proc GRASSFIELD_DRM=$tmp/drm \
    GRASSFIELD_LID_LOCK="$tmp/bin/lock" GRASSFIELD_LID_FALLBACK="$tmp/bin/fallback" bash "$root/packaging/bin/grassfield-lid" "$@"
}
# The fallback runs detached: give it a moment to record its call.
settle() { for _ in 1 2 3 4 5 6 7 8 9 10; do grep -q fallback "$tmp/calls.log" && return; sleep 0.1; done; }
reset() { : >"$tmp/calls.log"; }
calls() { cat "$tmp/calls.log"; }

desc="lid closed, no external display: the shell is asked to lock and the laptop panel is not touched"
reset; setup closed disconnected; lid closed
check bash -c 'grep -qx lock "$1/calls.log" && ! grep -q hyprctl "$1/calls.log"' _ "$tmp"

desc="lid closed with an external display: the shell is asked too (it decides: docked), the laptop panel (eDP-1) is switched off"
reset; setup closed connected; lid closed
check bash -c 'grep -qx lock "$1/calls.log" && grep -q "hyprctl eval hl.monitor({ output = \"eDP-1\", disabled = true })" "$1/calls.log"' _ "$tmp"

desc="the lock request is sent first, before the panel changes (logind may suspend right after the close)"
check bash -c '[[ $(head -n 1 "$1/calls.log") == lock ]]' _ "$tmp"

desc="the default lock command is the security process's lid entry point (lock lid on /usr/share/grassfield/shell/security.qml, ADR-0041 S2), never an unlock or another locker"
check bash -c 'grep -qx "LOCK_CMD=\"qs ipc -p /usr/share/grassfield/shell/security.qml call lock lid\"" "$1"' _ "$root/packaging/bin/grassfield-lid"

desc="the lid switch is bound once: system.lua, not bindings.lua"
check bash -c '[[ $(grep -c "switch:on:Lid Switch" "$1") == 1 ]] && ! grep -q "Lid Switch" "$2"' _ "$root/config/hypr/grassfield/system.lua" "$root/config/hypr/grassfield/bindings.lua"

desc="repeated events do not switch it off again (idempotent)"
reset; lid reconcile; lid closed
check bash -c '! grep -q hyprctl "$1/calls.log"' _ "$tmp"

desc="lid opened: the user's monitor configuration is applied again (reload), once"
reset; setup open connected; lid opened; lid reconcile
check bash -c '[[ $(grep -c "hyprctl reload" "$1/calls.log") == 1 ]]' _ "$tmp"

desc="external display unplugged while the lid is closed: the laptop panel comes back"
reset; setup closed connected; lid closed; reset; setup closed disconnected; lid reconcile
check bash -c 'grep -q "hyprctl reload" "$1/calls.log" && ! grep -q "disabled = true" "$1/calls.log"' _ "$tmp"

desc="lid open with an external display: nothing to do"
reset; setup open connected; lid reconcile
check bash -c '! grep -q hyprctl "$1/calls.log"' _ "$tmp"

desc="a machine without a lid: reconcile does nothing"
reset; rm -rf "$tmp/proc/LID0"; lid reconcile
check bash -c '! grep -q hyprctl "$1/calls.log"' _ "$tmp"

desc="a lid that /proc does not report as closed still sends the lock request (the switch event is the signal)"
mkdir -p "$tmp/proc/LID0"; reset; setup open disconnected; lid closed
check bash -c 'grep -qx lock "$1/calls.log"' _ "$tmp"

# Follow-up N3: the shell does not answer -> the lock is not dropped (restart + lock through the stand-in), except in
# clamshell mode; an answer from the shell never triggers the fallback.
desc="shell down, no external display: the stand-in is asked to restart the shell and lock (lock lock)"
reset; setup closed disconnected; FAKE_LOCK=fail lid closed; settle
check bash -c 'grep -qx "fallback lock lock" "$1/calls.log"' _ "$tmp"

desc="shell starting (Not ready...), no external display: the stand-in is asked too"
reset; setup closed disconnected; FAKE_LOCK="Not ready to accept queries yet" lid closed; settle
check bash -c 'grep -qx "fallback lock lock" "$1/calls.log"' _ "$tmp"

desc="shell down with an external display connected (clamshell): no fallback lock, the panel is still handled"
reset; setup closed connected; FAKE_LOCK=fail lid closed; settle
check bash -c '! grep -q fallback "$1/calls.log" && grep -q "disabled = true" "$1/calls.log"' _ "$tmp"
reset; setup open disconnected; lid reconcile

for answer in ok already-locked docked "refused: missing-pam"; do
  desc="the shell answers '$answer': no fallback"
  reset; setup closed disconnected; FAKE_LOCK="$answer" lid closed; settle
  check bash -c '! grep -q fallback "$1/calls.log"' _ "$tmp"
done

desc="an unknown argument is refused"
status=0; lid frobnicate 2>/dev/null || status=$?
check test "$status" = 2

desc="the Hyprland config binds the lid switch both ways and the monitor events, in the real session only"
check bash -c 'grep -q "switch:on:Lid Switch" "$1" && grep -q "switch:off:Lid Switch" "$1" && grep -q "monitor.added" "$1" && grep -q "monitor.removed" "$1" && grep -q "grassfield.system" "$2" && ! grep -q "grassfield.system" "$3"' _ \
  "$root/config/hypr/grassfield/system.lua" "$root/config/hypr/session.lua" "$root/config/hypr/dev.lua"

exit $fail
