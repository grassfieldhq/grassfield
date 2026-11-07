#!/usr/bin/env bash
# L1 nested scenario: a window moved to another display fits it (owner report on 1.0.0-rc6: "a maximized window moved to a smaller
# display overflows it", and its titlebar ended under the menu bar; docs/specs/tiling.md TL21, docs/specs/compositor.md FR56).
# Two outputs of different sizes: GF-REF and the nested window's WAYLAND-1, or a headless GF-FIT the script creates (1440 x 900
# by config/hypr/dev.lua's rule for any output). The source is the output whose work area is taller, the target the other.
#   F1 a Free window larger than the target's work area, moved to the target's Desktop (Hyprland's move to a workspace, as the
#      Overview or a key does): it fits that work area, its titlebar right below the target's menu bar
#   F2 a Free window that fits, moved there: its size is kept, its titlebar below the menu bar
#   F3 a filled window (Zoom is Fill) moved there: filled on the target (its tile record "fill" on that output, the target's
#      Fill frame)
#   F4 a Free window larger than the target's work area, dragged by its titlebar onto the target: it fits there
#   F5 the same by Hyprland's move (Super+drag): it fits there
# The work areas are the plugin's (`hyprctl grassfield-tiling`, logical px); the menu bar's bottom is each output's area top.
#
# Usage: tests/compositor/display_fit.sh
# NESTED only, bare: needs scripts/dev/nested-up.sh with the plugin (window-tiling) and the shell (its menu bar). Clients start
# through scripts/dev/isolated.sh on the nested socket; hyprctl only through scripts/nestctl (read-only, window moves and
# resizes, the plugin's tile verb, a headless output); pointer and keys through scripts/dev/pointer.sh and keys.sh.
# Exit: 0 PASS, 1 FAIL, 2 usage or environment error. Log: .dev/display-fit/run-<timestamp>.log.
set -uo pipefail

root=$(git -C "$(dirname "$0")" rev-parse --show-toplevel)
dev=$root/.dev
# shellcheck source=../../scripts/dev/pidfile.sh
. "$root/scripts/dev/pidfile.sh"
# shellcheck source=titlebar_geometry.sh
. "$root/tests/compositor/titlebar_geometry.sh" || exit 2
dev_nested_target "$dev" || exit 2
sock=$DEV_NESTED_SOCK sig=$DEV_NESTED_SIG
main=$(cat "$dev/main.instance" 2>/dev/null || true)
if [[ $sig == "$main" || $sig == "${HYPRLAND_INSTANCE_SIGNATURE:-}" || $sock == "${WAYLAND_DISPLAY:-}" ]]; then
  echo "display_fit: refusing: recorded nested instance is the main session" >&2
  exit 2
fi
bus=$(cat "$dev/bus.address" 2>/dev/null || echo disabled:)

work=$dev/display-fit
mkdir -p "$work"
log=$work/run-$(date +%Y%m%d-%H%M%S).log
say() { printf '%s %s\n' "$(date '+%H:%M:%S')" "$*" | tee -a "$log"; }
ctl() { timeout 10 "$root/scripts/nestctl" "$@"; }
pointer() { timeout 30 "$root/scripts/dev/pointer.sh" output "$@" >>"$log" 2>&1; }
keys() { timeout 30 "$root/scripts/dev/keys.sh" "$@" >>"$log" 2>&1; }

ctl -j grassfield 2>/dev/null | jq -e '.features | index("window-tiling")' >/dev/null 2>&1 ||
  { echo "display_fit: the plugin does not advertise window-tiling (load this tree's plugin)" >&2; exit 2; }
created=""
if [[ $(ctl monitors -j | jq 'length') -lt 2 ]]; then
  ctl output create headless GF-FIT >>"$log" 2>&1
  created=GF-FIT
  sleep 2
fi

pids=()
cleanup() {
  local p
  for p in "${pids[@]}"; do pkill -P "$p" 2>/dev/null; kill "$p" 2>/dev/null; done
  [[ -n $created ]] && ctl output remove "$created" >>"$log" 2>&1
}
trap cleanup EXIT

fail=0
check() { if [[ $2 == 0 ]]; then say "  $1: OK   ($3)"; else say "  $1: FAIL ($3)"; fail=1; fi; }
# The plugin's work area of an output: "x y w h" (logical px; its top is the menu bar's bottom).
area_of() { ctl grassfield-tiling | jq -r --arg o "$1" '.outputs[] | select(.name == $o) | .area | "\(.x) \(.y) \(.w) \(.h)"'; }
origin_of() { ctl monitors -j | jq -r --arg o "$1" '.[] | select(.name == $o) | "\(.x) \(.y)"'; }
desktop_of() { ctl monitors -j | jq -r --arg o "$1" '.[] | select(.name == $o) | .activeWorkspace.id'; }
win() { ctl clients -j | jq -r --arg t "$1" '[.[] | select(.title == $t)][0] | select(. != null) | "\(.at[0]) \(.at[1]) \(.size[0]) \(.size[1]) \(.address)"'; }

# Source and target: the output whose work area is taller, and the other one.
read -r o1 o2 < <(ctl monitors -j | jq -r '[.[].name] | "\(.[0]) \(.[1])"')
read -r _ _ _ h1 < <(area_of "$o1")
read -r _ _ _ h2 < <(area_of "$o2")
if ((h1 >= h2)); then src=$o1 dst=$o2; else src=$o2 dst=$o1; fi
read -r sx sy sw sh < <(area_of "$src")
read -r dx dy dw dh < <(area_of "$dst")
read -r sox soy < <(origin_of "$src")
say "display_fit: source $src (work area ${sw}x${sh} at $sx,$sy), target $dst (work area ${dw}x${dh} at $dx,$dy)"
((sh > dh)) || { say "setup error: the two work areas are as tall (${sh} and ${dh})"; exit 2; }
tb=$GF_TB_HEIGHT

# A foot titled $1 on the source, $2 x $3 (surface, logical px), its frame at the source area's top-left + (20, 0).
open_on_src() {
  pointer "$src" abs 300 300 sleep 100
  env -u DISPLAY WAYLAND_DISPLAY="$sock" DBUS_SESSION_BUS_ADDRESS="$bus" setsid "$root/scripts/dev/isolated.sh" --name "fit-$1" \
    foot -T "$1" sh -c 'exec sleep 100000' >>"$log" 2>&1 </dev/null &
  pids+=($!)
  local i a
  for i in $(seq 1 80); do [[ -n $(win "$1") ]] && break; sleep 0.25; done
  read -r _ _ _ _ a < <(win "$1")
  [[ -n $a ]] || return 1
  ctl dispatch "hl.dsp.window.move({ workspace = '$(desktop_of "$src")', window = 'address:$a' })" >>"$log" 2>&1
  sleep 0.5
  ctl dispatch "hl.dsp.window.resize({ x = $2, y = $3, exact = true, window = 'address:$a' })" >>"$log" 2>&1
  sleep 0.5
  ctl dispatch "hl.dsp.window.move({ x = $((sx + 20)), y = $((sy + tb)), window = 'address:$a' })" >>"$log" 2>&1
  sleep 0.8
}
close_win() { local p; p=$(ctl clients -j | jq -r --arg t "$1" '[.[] | select(.title == $t)][0].pid // empty'); [[ -n $p ]] && kill "$p" 2>/dev/null; sleep 0.6; }
# The window titled $1 lies within the target's work area: frame (surface + titlebar band) inside it, top at its top when
# $2 is "top" (it was too tall), its size $3 x $4 when given.
fits_target() { # title top|any [w h]
  local x y w h _a
  read -r x y w h _a < <(win "$1")
  say "    $1: ${w}x${h} at $x,$y; frame top $((y - tb)), bottom $((y + h)); target area $dx,$dy ${dw}x${dh}"
  (( x >= dx - 1 && x + w <= dx + dw + 1 && y - tb >= dy - 1 && y + h <= dy + dh + 1 )) || return 1
  [[ $2 == top ]] && { (( y - tb >= dy - 1 && y - tb <= dy + 1 )) || return 1; }
  [[ -n ${3:-} ]] && { (( w == $3 && h == $4 )) || return 1; }
  return 0
}

big_w=$((dw + 40 < sw ? dw + 40 : sw - 40)) big_h=$((dh - tb + 30))
((big_h + tb <= sh)) || big_h=$((sh - tb))
say "  an oversize window: ${big_w}x${big_h} (frame $((big_h + tb)) tall; the target's area is $dh)"

# ---- F1 ----
if open_on_src gf-fit-1 "$big_w" "$big_h"; then
  read -r _ _ _ _ a < <(win gf-fit-1)
  ctl dispatch "hl.dsp.window.move({ workspace = '$(desktop_of "$dst")', window = 'address:$a' })" >>"$log" 2>&1
  sleep 1.2
  fits_target gf-fit-1 top
  check "F1 moved to the target's Desktop, the oversize window fits its work area below the menu bar" $? "see the line above"
  close_win gf-fit-1
else
  check "F1 foot mapped" 1 ""
fi

# ---- F2 ----
if open_on_src gf-fit-2 600 400; then
  read -r _ _ _ _ a < <(win gf-fit-2)
  ctl dispatch "hl.dsp.window.move({ workspace = '$(desktop_of "$dst")', window = 'address:$a' })" >>"$log" 2>&1
  sleep 1.2
  fits_target gf-fit-2 any 600 400
  check "F2 a window that fits keeps its size there, below the menu bar" $? "see the line above"
  close_win gf-fit-2
fi

# ---- F3 ----
if open_on_src gf-fit-3 600 400; then
  read -r _ _ _ _ a < <(win gf-fit-3)
  ctl dispatch "hl.plugin.grassfield.tile(\"$a\", \"fill\")" >>"$log" 2>&1
  sleep 1
  ctl dispatch "hl.dsp.window.move({ workspace = '$(desktop_of "$dst")', window = 'address:$a' })" >>"$log" 2>&1
  sleep 1.2
  rec=$(ctl grassfield-tiling | jq -r --arg a "${a#0x}" '[.outputs[] | . as $o | .windows[] | select(.address == $a) | "\(.place) \($o.name)"][0] // "none"')
  read -r x y w h _a < <(win gf-fit-3)
  m=8
  say "    gf-fit-3: record '$rec', ${w}x${h} at $x,$y (target fill: $((dw - 2 * m))x$((dh - 2 * m - tb)) at $((dx + m)),$((dy + m + tb)))"
  [[ $rec == "fill $dst" ]] && (( x == dx + m && y == dy + m + tb && w == dw - 2 * m && h == dh - 2 * m - tb ))
  check "F3 a filled window moved to the target's Desktop is filled there" $? "record '$rec'"
  close_win gf-fit-3
fi

# ---- F4 ----
if open_on_src gf-fit-4 "$big_w" "$big_h"; then
  read -r x y w h _a < <(win gf-fit-4)
  gx=$((x + w / 2 - sox)) gy=$((y - GF_TB_MID - soy))
  read -r dox doy < <(origin_of "$dst")
  tx=$((dox - sox + dx - dox + dw / 2)) ty=$((doy - soy + dy - doy + 60))
  pointer "$src" abs "$gx" $((gy + 3)) sleep 120 abs "$gx" "$gy" sleep 200 down sleep 150 drag $(((gx + tx) / 2)) "$gy" sleep 100 drag "$tx" "$ty" sleep 400 up sleep 300
  sleep 1
  fits_target gf-fit-4 top
  check "F4 dragged by its titlebar onto the target, the oversize window fits there" $? "see the line above"
  close_win gf-fit-4
fi

# ---- F5 ----
if open_on_src gf-fit-5 "$big_w" "$big_h"; then
  read -r x y w h _a < <(win gf-fit-5)
  gx=$((x + w / 2 - sox)) gy=$((y + h / 2 - soy))
  read -r dox doy < <(origin_of "$dst")
  tx=$((dox - sox + dx - dox + dw / 2)) ty=$((doy - soy + dy - doy + dh / 2))
  keys -M logo -s 3200 -m logo &
  k=$!
  sleep 0.3
  pointer "$src" abs "$gx" $((gy + 3)) sleep 100 abs "$gx" "$gy" sleep 100 down sleep 150 drag $(((gx + tx) / 2)) "$gy" sleep 100 drag "$tx" "$ty" sleep 400 up sleep 300
  wait "$k" 2>/dev/null
  sleep 1
  fits_target gf-fit-5 top
  check "F5 Hyprland's move (Super+drag) onto the target: the oversize window fits there" $? "see the line above"
  close_win gf-fit-5
fi

say "display_fit: plugin log: $(ctl rollinglog 2>/dev/null | grep -a 'made to fit' | tail -n 6 | sed 's/.*\[grassfield\] //' | tr '\n' ';')"
say "display_fit: $([[ $fail == 0 ]] && echo PASS || echo FAIL)"
exit "$fail"
