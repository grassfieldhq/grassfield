#!/usr/bin/env bash
# Readiness of this tree's nested session for the nested security scenarios. Sourced by tests/security/reload_locked.sh
# and tests/security/lock_privacy.sh. Read-only: never starts, stops or signals anything and types nothing.
#
# scripts/dev/nested-up.sh returns once Hyprland lists the nested instance and the shell process is spawned. The headless
# output GF-REF comes later (config/hypr/dev.lua creates it from Hyprland's start callback, which waits for Hyprland's
# 2 s launch fallback on a loaded machine), and the shell answers IPC only once its configuration has loaded (5-9 s after
# its start in the integrator's run of 2026-11-04, load 3-8). `just test-security-nested` starts the scenarios at once:
# lock_privacy.sh read the shell's empty `lock status` answer as "already locked" and stopped, and reload_locked.sh opened
# its probe window before GF-REF existed (the window never appeared).
#
# nested_ready <instance> <socket> <lock root> <seconds>
#   Waits at most <seconds> (each query bounded by timeout(1)) until the nested compositor lists GF-REF and the process
#   that holds the lock answers `lock status` with a lock state. <lock root> is the path its `qs ipc -p` names: since
#   ADR-0041 step 1, S2 the security process's root, <tree>/shell/security.qml (scripts/dev/shell-run.sh starts it beside
#   the shell). An empty or unknown answer means "not ready", never a lock state.
#   Returns 0 when ready (nested_ready_state: the state, nested_ready_ms: the time waited); 1 on timeout and 2 when the
#   process refuses the dev hooks (not a dev session), with the reason in nested_ready_why. Callers FAIL and stop on
#   anything but 0: no scenario runs on an unknown lock state.

nested_ready_state="" nested_ready_ms="" nested_ready_why=""

nested_ready() { # <instance> <socket> <lock root> <seconds>
  local sig=$1 sock=$2 shell=$3 secs=$4 start deadline output=0 answer="" monitors
  nested_ready_state="" nested_ready_ms="" nested_ready_why=""
  [[ $secs =~ ^[0-9]+$ ]] || { nested_ready_why="bad timeout '$secs'"; return 1; }
  start=${EPOCHREALTIME/./}
  deadline=$((SECONDS + secs))
  while :; do
    if ((!output)); then
      monitors=$(env WAYLAND_DISPLAY="$sock" HYPRLAND_INSTANCE_SIGNATURE="$sig" timeout -k 2 5 hyprctl -j monitors 2>/dev/null)
      jq -e 'type == "array" and any(.[]; .name == "GF-REF")' <<<"$monitors" >/dev/null 2>&1 && output=1
    fi
    if ((output)); then
      answer=$(env WAYLAND_DISPLAY="$sock" HYPRLAND_INSTANCE_SIGNATURE="$sig" timeout -k 2 5 qs ipc -p "$shell" call lock status 2>/dev/null)
      case $answer in
        unlocked | locking | locked | authenticating | releasing)
          nested_ready_state=$answer
          nested_ready_ms=$(((${EPOCHREALTIME/./} - start) / 1000))
          return 0
          ;;
        refused)
          nested_ready_why="the security process refuses the dev hooks (lock status -> refused): not a dev session (GRASSFIELD_DEV=1 without GRASSFIELD_SESSION=1)"
          return 2
          ;;
      esac
    fi
    ((SECONDS < deadline)) || break
    sleep 0.25
  done
  if ((!output)); then
    nested_ready_why="the nested compositor did not list the output GF-REF within $secs s (see .dev/hyprland.log)"
  else
    nested_ready_why="the nested security process did not answer \`lock status\` with a lock state within $secs s (last answer '${answer:-none}'; see .dev/security.log)"
  fi
  return 1
}
