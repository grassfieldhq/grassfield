#!/usr/bin/env bash
# Pointer focus on a Grassfield layer surface that maps (or takes the keyboard, or unmaps) under a resting pointer (macOS
# model: what appears or disappears under a still pointer gets the next click; a trackpad tap does not move the pointer).
# Integrator finding 2026-10-22 (docs/specs/menubar.md "Known limitations"): with a bar menu open, a click with no pointer
# motion since the menu opened reached no surface; 1 px of motion first and it reached the menu's overlay and closed it.
# Cause (docs/specs/compositor.md FR51): Hyprland 0.56.2 gives a layer that takes the keyboard the pointer focus with the
# monitor offset counted twice, so on GF-REF (x = 1440) the overlay was told the pointer at x - 1440 until it moved; on an
# output at the layout origin (WAYLAND-1) the same clicks worked. grassfield-compositor 0.12.0-pointer re-runs Hyprland's
# pointer focus at the cursor afterwards (feature layer-pointer).
#
# Usage: tests/compositor/layer_pointer.sh [check | probe] [--output NAME] [--expect plugin | degraded]
#   check (default)  every case below; exit 0 PASS, 1 FAIL, 2 environment error
#   probe            the same cases, with Hyprland's log lines of each step and the pointer devices (diagnostic)
#   --output NAME    the output whose menu bar is used (default GF-REF, which is not at the layout origin)
#   --expect         default: "plugin" when `hyprctl grassfield` advertises layer-pointer, else "degraded". "plugin" with an
#                    older plugin (or none) shows the defect as FAIL lines.
# NESTED only, run BARE (never chained or with a VAR= prefix): needs this tree's nested session with the real shell
# (scripts/dev/nested-up.sh, or a tests/visual scenario run first). Pointer through scripts/dev/pointer.sh (each call is a
# new virtual pointer; a call without `abs` sends no motion at all), shell state through tests/visual/ipc.sh, letters
# through scripts/dev/keys.sh (Escape only), a probe window through scripts/dev/isolated.sh on the nested socket;
# scripts/nestctl for reads only. Only processes started here are stopped.
#
# Cases:
#   map-same      one pointer: click the app menu title (the menu opens on the press, while the button is down), then click
#                 again on the same pixel without any motion: the menu closes (macOS: a click on the open title closes it)
#   map-new       the same with the second click from a new pointer device and no motion event at all
#   map-ipc       the menu opened over a resting pointer by IPC (no press), then a click without motion closes it
#   control       the same with 1 px of motion before the second click (Hyprland alone handles it)
#   unmap-window  the pointer rests on a mouse-reporting foot window; a menu opened by IPC covers it and closes with Escape;
#                 a click without motion reaches foot (its SGR press is captured). Hyprland handles layer unmaps itself
#                 (CLayerSurface::onUnmap runs simulateMouseMovement): a regression check, with or without the plugin
#   health        Hyprland alive, no grassfield exception in its log
# Without the layer-pointer feature (C2: nested-up.sh --no-plugin, scripts/nestctl plugin unload, an older plugin) the
# shell must still work: the map cases are reported as KNOWN (Hyprland 0.56.2 alone) and the others are checked.
# Logs: .dev/layer-pointer/run-<timestamp>-<mode>/.
set -uo pipefail

root=$(git -C "$(dirname "$0")" rev-parse --show-toplevel)
dev=$root/.dev
out=GF-REF
mode=check
expect=""
usage() { echo "usage: layer_pointer.sh [check | probe] [--output NAME] [--expect plugin | degraded]" >&2; exit 2; }
while (($#)); do
  case $1 in
    check | probe) mode=$1 ;;
    --output) out=${2:-}; [[ -n $out ]] || usage; shift ;;
    --expect) expect=${2:-}; [[ $expect == plugin || $expect == degraded ]] || usage; shift ;;
    *) usage ;;
  esac
  shift
done
# shellcheck source=../../scripts/dev/pidfile.sh
. "$root/scripts/dev/pidfile.sh"
dev_nested_target "$dev" || exit 2
sock=$DEV_NESTED_SOCK sig=$DEV_NESTED_SIG hypr_pid=$DEV_NESTED_PID

for tool in jq foot qs; do
  command -v "$tool" >/dev/null || { echo "layer_pointer: $tool not installed" >&2; exit 2; }
done

run=$dev/layer-pointer/run-$(date +%Y%m%d-%H%M%S)-$mode
mkdir -p "$run"
log=$run/run.log
hyprlog=${XDG_RUNTIME_DIR:?}/hypr/$sig/hyprland.log
say() { printf '%s %s\n' "$(date '+%H:%M:%S.%3N')" "$*" | tee -a "$log"; }
nestctl() { timeout 10 "$root/scripts/nestctl" "$@"; }
pointer() { timeout 20 "$root/scripts/dev/pointer.sh" output "$out" "$@" >>"$log" 2>&1; }
keys() { timeout 10 "$root/scripts/dev/keys.sh" "$@" >>"$log" 2>&1; }
ipc() { timeout 5 "$root/tests/visual/ipc.sh" "$@" >>"$log" 2>&1; }
ipcq() { timeout 5 "$root/tests/visual/ipc.sh" "$@" 2>>"$log"; } # its answer on stdout
ms() { sleep "$(awk -v m="$1" 'BEGIN { printf "%.3f", m / 1000 }')"; }
kind() { ipcq menubar openKind | tr -d '"'; }
closed() { [[ -z $(kind) ]]; }
menu_open() { [[ -n $(kind) ]]; }
wait_for() { # <ms> <command...>: true once the command succeeds (polled every 100 ms), false after <ms>
  local limit=$1 t0
  shift
  t0=$(date +%s%3N)
  until "$@"; do
    (($(date +%s%3N) - t0 > limit)) && return 1
    ms 100
  done
}
overlay_mapped() { nestctl layers -j 2>/dev/null | jq -e '[.. | objects | select(.namespace? == "grassfield-overlay")] | length > 0' >/dev/null 2>&1; }
overlay_gone() { ! overlay_mapped; }

features=$(HYPRLAND_INSTANCE_SIGNATURE=$sig timeout 5 hyprctl -j grassfield 2>/dev/null | jq -c '.features' 2>/dev/null || true)
if [[ -z $expect ]]; then
  expect=degraded
  jq -e 'index("layer-pointer")' <<<"${features:-null}" >/dev/null 2>&1 && expect=plugin
fi

fail=0
check() { # <name> <command...>
  local name=$1
  shift
  if "$@"; then
    say "PASS: $name"
  elif [[ $expect == degraded && $name == map-* ]]; then
    say "KNOWN (no layer-pointer feature, Hyprland 0.56.2 alone): $name"
  else
    say "FAIL: $name"
    fail=1
  fi
}

lines0=$(grep -ac "" "$hyprlog" 2>/dev/null || echo 0)
mark=$lines0
hyprlines() { # Hyprland log lines since the last call (probe mode)
  local n
  n=$(grep -ac "" "$hyprlog" 2>/dev/null || echo 0)
  if [[ $mode == probe ]]; then
    tail -n +"$((mark + 1))" "$hyprlog" 2>/dev/null | head -n "$((n - mark))" | grep -aE 'LayerSurface .* (mapped|unmapped)|Set keyboard focus|BUG|sendButton|\[grassfield\] layer pointer' | sed 's/^/    hypr: /' | tee -a "$log"
  fi
  mark=$n
}

pids=()
cleanup() {
  ipc menubar close
  local p
  for p in "${pids[@]}"; do dev_may_signal "$p" && kill "$p" 2>/dev/null; done
}
trap cleanup EXIT
trap 'exit 130' INT HUP
trap 'exit 143' TERM

ipcq lock status >/dev/null && ipcq overview status >/dev/null || { say "setup error: no nested shell answering (tests/visual/ipc.sh lock status: the security process, ADR-0041 S2; overview status: the UI)"; exit 2; }
read -r mon_x mon_y mon_w mon_h < <(nestctl monitors -j | jq -r --arg o "$out" '.[] | select(.name == $o) | "\(.x) \(.y) \(.width) \(.height)"')
[[ -n ${mon_w:-} ]] || { say "setup error: output $out not found"; exit 2; }
app_x=$(ipcq menubar bridgeState "$out" | jq -r '.bar[] | select(.kind == "app") | (.x + .w / 2 | floor)' | head -n 1)
[[ $app_x =~ ^[0-9]+$ ]] || { say "setup error: no app title in the menu bar of $out"; exit 2; }
say "layer_pointer ($mode): nested pid $hypr_pid, output $out ${mon_w}x${mon_h} at $mon_x,$mon_y, app title at x=$app_x, expect $expect"
say "  plugin features now: ${features:-none (no grassfield hyprctl command)}"
if [[ $mode == probe ]]; then
  nestctl devices -j | jq -c '{mice: [.mice[].name]}' | tee -a "$log"
fi

reset_menus() {
  ipc menubar close
  wait_for 3000 closed
  ms 400
}

# map-same: one virtual pointer for both clicks; the menu opens on the first press (macOS), the overlay maps under the
# pointer, and the second click comes from the same pixel with no motion in between.
reset_menus
pointer abs "$app_x" 12 sleep 200 click sleep 700 click sleep 300
hyprlines
wait_for 1500 closed
check "map-same: a second click without motion closes the menu (now '$(kind)')" closed

# map-new: the first click as above; the second from a new pointer device that sends no motion at all.
reset_menus
pointer abs "$app_x" 12 sleep 200 click
wait_for 2000 menu_open || say "  note: the menu did not open after the first click"
opened=$(kind)
ms 400
hyprlines
pointer click
wait_for 1500 closed
hyprlines
check "map-new: a click from a new pointer without motion closes the menu (opened '${opened:-none}', now '$(kind)')" closed

# map-ipc: the pointer rests on the title; the menu opens by IPC (no press), so the overlay maps under a still pointer.
reset_menus
pointer abs "$app_x" 12 sleep 300
ipc menubar open app "$out"
wait_for 2000 menu_open || say "  note: the menu did not open by IPC"
opened=$(kind)
ms 500
hyprlines
pointer click
wait_for 1500 closed
hyprlines
check "map-ipc: a click without motion on a menu opened under the still pointer closes it (opened '${opened:-none}', now '$(kind)')" closed

# The 1-px control (Hyprland handles motion itself, with or without the plugin).
reset_menus
pointer abs "$app_x" 12 sleep 200 click
wait_for 2000 menu_open
ms 400
pointer abs "$((app_x + 1))" 12 sleep 100 click
wait_for 1500 closed
hyprlines
if closed; then say "PASS: control: a click after 1 px of motion closes the menu"; else say "FAIL: control: a click after 1 px of motion closes the menu (now '$(kind)')"; fail=1; fi

# unmap-window: a mouse-reporting foot under the pointer; the overlay maps over it and unmaps (Escape) while the pointer
# rests; the next click without motion must reach foot.
reset_menus
cap=$run/foot.cap
: >"$cap"
pointer abs $((mon_w / 2)) $((mon_h / 2)) sleep 100 # new windows open on the output under the pointer
WAYLAND_DISPLAY=$sock setsid "$root/scripts/dev/isolated.sh" --name layer-pointer foot -T lp-foot -e sh -c \
  'stty raw -echo; printf "\033[?1000h\033[?1006h"; exec cat -v >"$0"' "$cap" >/dev/null 2>&1 </dev/null &
pids+=("$!")
foot_geom() { nestctl clients -j | jq -r '.[] | select(.title == "lp-foot") | "\(.at[0]) \(.at[1]) \(.size[0]) \(.size[1])"' | head -n 1; }
foot_mapped() { [[ -n $(foot_geom) ]]; }
wait_for 10000 foot_mapped || say "  note: foot did not map"
ms 800
read -r fx fy fw fh <<<"$(foot_geom)"
if [[ -n ${fw:-} ]]; then
  px=$((fx - mon_x + fw / 2)) py=$((fy - mon_y + fh / 2))
  pointer abs "$px" "$py" sleep 150 abs $((px + 2)) $((py + 1)) sleep 300
  sgr() { grep -aoE '\[<[0-9]+;[0-9]+;[0-9]+[Mm]' "$cap" | tr '\n' ' '; }
  before=$(sgr)
  ipc menubar open app "$out"
  wait_for 2000 menu_open || say "  note: the menu did not open by IPC"
  wait_for 2000 overlay_mapped || say "  note: no grassfield-overlay layer listed"
  ms 500
  keys -k Escape
  wait_for 2000 closed || say "  note: Escape did not close the menu"
  wait_for 3000 overlay_gone || say "  note: the overlay stayed mapped"
  ms 500
  hyprlines
  pointer click
  ms 600
  hyprlines
  after=$(sgr)
  say "  foot SGR events before: '${before}' after: '${after}'"
  check "unmap-window: a click without motion after the menu closed reaches the window under the pointer" test "${#after}" -gt "${#before}"
else
  say "FAIL: unmap-window: setup (foot window not found)"
  fail=1
fi

# health
if kill -0 "$hypr_pid" 2>/dev/null; then say "PASS: health: nested Hyprland alive"; else say "FAIL: health: nested Hyprland gone"; fail=1; fi
exc=$(tail -n +"$((lines0 + 1))" "$hyprlog" 2>/dev/null | grep -ac '\[grassfield\].*exception' || true)
if [[ ${exc:-0} == 0 ]]; then say "PASS: health: no grassfield exception in the log"; else say "FAIL: health: $exc grassfield exception line(s)"; fail=1; fi

say "result: $([[ $fail == 0 ]] && echo PASS || echo FAIL) (logs $run)"
exit "$fail"
