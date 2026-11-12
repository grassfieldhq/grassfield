#!/usr/bin/env bash
# xdg_toplevel_drag_v1 (URR-030, ADR-0036 amendment 2026-11-08, docs/specs/compositor.md "Toplevel drag (xdg_toplevel_drag_v1)"):
# a browser tab torn off moves with the pointer, drops back into a tab strip, and tiles like any window being dragged. Driven by
# a fixture client that uses the protocol as Chromium does (tests/compositor/toplevel-drag-fixture/tdrag.c) on GF-REF; each case
# starts a fresh fixture (its source window at 100,200 and its target window at 1000,200, 400x300 each, output-relative):
#   T0 global      the fixture sees xdg_toplevel_drag_manager_v1 version 1; the capabilities list toplevel-drag
#   T1 follows     a press on the source starts the drag; the torn window maps under the pointer at the client's offset (40,12)
#                  and follows it to two more places (2 px slack, far from every edge so that nothing snaps)
#   T1b geometry   Chromium's torn window (980x620, its window geometry changing right after its map): it stays under the
#                  resting pointer (Hyprland fitted it into the work area; the plugin puts it back at its commit)
#   T2 target      over the target window, with the torn window under the pointer, the drag enters the TARGET, and never the
#                  torn window: the attached window takes no part in the selection of the drag target
#   T3 drop        released over the target: drop on the target, dnd_drop_performed, the object destroyed after it; the torn
#                  window stays where it was released, not tiled
#   T4 tile        dragged to the free edge, rested past the preview delay, released over nothing (Hyprland cancels: no client
#                  accepts there): the torn window takes that half (tile record "tiled", place left or right)
#   T5 escape      the same drag ended by Escape before the release: cancelled, no tile, the plugin logs the cancel
#   T6 merge       entering the target unmaps the torn window (the plugin detaches it); leaving attaches and maps it again and
#                  it follows the pointer again
#   T7 existing    the source window itself attached (mapped) before start_drag: it moves by the pointer's delta, no jump
#   T8 errors      attach while attached: toplevel_attached; destroy during the drag: ongoing_drag; a second object for one
#                  source: invalid_source (each the fixture's protocol error, Hyprland alive)
#   T9 chromium    (when chromium is installed) the second tab of a two-tab window dragged down: a new chromium window maps and
#                  follows the pointer; released at the free edge: tiled. Best effort (tab positions are measured on Chromium
#                  155): a missing second window is reported NOT VERIFIED, not FAIL
#   T10b finish    a target that finishes without receiving, as Chromium's tab drag (Hyprland 0.56.2 then cancels): the
#                  source gets dnd_drop_performed before that cancel (the plugin's), so Chromium keeps the drop
#   T10 late       (review of aa8211de) released over a target that calls wl_data_offer.finish 2.5 s later (Hyprland 0.56.2
#                  sends dnd_drop_performed only then): the window's drag ends at the release (the plugin logs it); the pointer
#                  moved 2 px under the still-attached window gives it no enter (counter-review of 2dcae1f2); the pointer moves
#                  on and the window stays; then the late finish ends the drag without a protocol error
#   T11 never      the same with a target that never finishes: the window stays where it was released, Hyprland alive; Escape
#                  then ends Hyprland's drag
#   T12 source     the client destroys the wl_data_source mid-drag: a cancel (logged), the window follows no more, no error
#   T13 role       the client destroys the torn window's xdg_toplevel mid-drag: detached (logged), the drag goes on, no error
#   T14 killed     the client killed (SIGKILL) while its torn window follows the pointer: Hyprland alive, no plugin exception
#   T15 selection  the drag's source also passed to set_selection: protocol error invalid_source
#   T16 display    (with a second output) the torn window dragged onto the other output and released there: it takes that
#                  output (SKIP, NOT VERIFIED, with one output)
#   Scale: positions are logical (read with the output's scale); run it again after `scripts/dev/nested-up.sh --ref-scale 1.25`.
#   C1/C2          the plugin unloaded while the torn window follows the pointer: Hyprland alive, the drag ends as Hyprland's
#                  plain drag and drop, a new fixture sees no global; loaded again: the global is back
# Usage (bare command, nested session of this tree running with the plugin loaded): tests/compositor/toplevel_drag.sh [--no-c1]
#   [--plugin PATH]   (PATH: the library the session loaded, for the C1/C2 unload and load; default compositor/build/...so)
# NESTED only: hyprctl through scripts/nestctl, input through scripts/dev/pointer.sh and tests/tools/vkbd/vkbd.sh, clients
# through scripts/dev/isolated.sh. Exit: 0 PASS, 1 FAIL, 2 usage or environment error. Logs: .dev/toplevel-drag/run-<timestamp>/.
set -uo pipefail

root=$(git -C "$(dirname "$0")" rev-parse --show-toplevel)
plugin_path=$root/compositor/build/grassfield-compositor.so
c1=1
while [[ $# -gt 0 ]]; do
  case $1 in
    --no-c1) c1=0 ;;
    --plugin) plugin_path=${2:?--plugin needs the path the session loaded}; shift ;;
    *) echo "usage: tests/compositor/toplevel_drag.sh [--no-c1] [--plugin PATH]" >&2; exit 2 ;;
  esac
  shift
done
dev=$root/.dev
out=GF-REF
# shellcheck source=../../scripts/dev/pidfile.sh
. "$root/scripts/dev/pidfile.sh"
dev_nested_target "$dev" || exit 2
sock=$DEV_NESTED_SOCK sig=$DEV_NESTED_SIG hypr_pid=$DEV_NESTED_PID
main=$(cat "$dev/main.instance" 2>/dev/null || true)
if [[ $sig == "$main" || $sig == "${HYPRLAND_INSTANCE_SIGNATURE:-}" || $sock == "${WAYLAND_DISPLAY:-}" ]]; then
  echo "toplevel_drag: refusing: recorded nested instance is the main session" >&2
  exit 2
fi
bus=$(cat "$dev/bus.address" 2>/dev/null || echo disabled:)

run=$dev/toplevel-drag/run-$(date +%Y%m%d-%H%M%S)
mkdir -p "$run"
log=$run/run.log
say() { printf '%s %s\n' "$(date '+%H:%M:%S.%3N')" "$*" | tee -a "$log"; }
nestctl() { timeout 10 "$root/scripts/nestctl" "$@"; }
pointer() { timeout 60 "$root/scripts/dev/pointer.sh" output "$out" "$@" >>"$log" 2>&1; }
keys() { timeout 10 "$root/tests/tools/vkbd/vkbd.sh" "$@" >>"$log" 2>&1; }
hyprlog=${XDG_RUNTIME_DIR:-/run/user/$(id -u)}/hypr/$sig/hyprland.log
fail=0
check() {
  local name=$1
  shift
  if "$@"; then say "PASS: $name"; else say "FAIL: $name"; fail=1; fi
}
# The plugin logged a line matching PATTERN (Hyprland's in-memory log, then its file), polled for up to 3 s.
plugin_logged() {
  local _ l
  for _ in $(seq 1 15); do
    l=$(nestctl rollinglog 2>/dev/null)
    grep -aq -- "$1" <<<"$l" && return 0
    grep -aq -- "$1" "$hyprlog" 2>/dev/null && return 0
    sleep 0.2
  done
  return 1
}
hypr_alive() { kill -0 "$hypr_pid" 2>/dev/null && nestctl version >/dev/null 2>&1; }
# A check of a plugin log line. The plugin's request log budget (FR24: 20 lines at once, then 1 per second) may hold a line back
# during a burst, and says so only on the next line it writes ("N similar line(s) held back"), which may come after the check or
# never (integrator nested run of aa1f0ba8: T4 at scale 1.25, its tile record PASS, its log line missing, no "held back" yet).
# With a proof (a command checking what the line reports, such as the tile record), a missing line is a NOTE when the proof
# holds, and a FAIL only when neither the log nor the proof shows it. Without a proof, a missing line is a NOTE when the log
# shows lines held back (nested run of 1c576658, T4 at load 22-28). The plugin's last toplevel-drag lines go to the run log.
check_log() { # <name> <pattern> [<proof command> [<args>...]]
  local name=$1 pattern=$2
  shift 2
  if plugin_logged "$pattern"; then say "PASS: $name"; return; fi
  {
    echo "  $name: not in the log; the plugin's last toplevel-drag lines:"
    { nestctl rollinglog 2>/dev/null; tail -n 600 "$hyprlog" 2>/dev/null; } | grep -a 'toplevel drag: ' | tail -n 12 | sed 's/^/    /'
  } >>"$log"
  if (($# > 0)); then
    if "$@"; then
      say "NOTE: $name: not in the log (the plugin's request log budget, FR24); what it reports is proven by: $*"
      return
    fi
  elif { nestctl rollinglog 2>/dev/null; tail -n 600 "$hyprlog" 2>/dev/null; } | grep -aq "similar line(s) held back"; then
    say "NOTE: $name: not in the log; the plugin's request log budget held lines back (FR24)"
    return
  fi
  say "FAIL: $name"
  fail=1
}
plugin_loaded() { nestctl -j plugin list 2>/dev/null | jq -e '[.[]? | select(.name == "grassfield-compositor")] | length > 0' >/dev/null; }

plugin_loaded || { echo "toplevel_drag: the plugin is not loaded" >&2; exit 2; }
# Logical sizes (the pixels divided by the scale): the layout, pointer.sh and `clients -j` are logical.
read -r mx my mw mh mscale < <(nestctl monitors -j | jq -r --arg o "$out" \
  '.[] | select(.name == $o) | "\(.x) \(.y) \((.width / .scale) | floor) \((.height / .scale) | floor) \(.scale)"')
[[ -n ${mx:-} ]] || { echo "toplevel_drag: output $out not found" >&2; exit 2; }
neighbour_on() { # left|right
  nestctl monitors -j | jq -r --arg o "$out" --arg side "$1" --argjson x "$mx" --argjson w "$mw" --argjson y "$my" --argjson h "$mh" \
    '[.[] | (.lw = ((.width / .scale) | floor)) | (.lh = ((.height / .scale) | floor))
       | select(.name != $o and .y < ($y + $h) and (.y + .lh) > $y
       and (if $side == "left" then (.x + .lw) == $x else .x == ($x + $w) end)) | .name][0] // ""'
}
other_output=$(nestctl monitors -j | jq -r --arg o "$out" '[.[] | select(.name != $o and (.disabled | not))][0].name // ""')
if [[ -z $(neighbour_on right) ]]; then
  side=right edge=$((mw - 2))
elif [[ -z $(neighbour_on left) ]]; then
  side=left edge=1
else
  side="" edge=""
fi

fixture=$root/tests/compositor/toplevel-drag-fixture/tdrag.sh
"$fixture" --build >>"$log" 2>&1 || { say "setup error: the fixture did not build"; exit 2; }

fixture_pid=""
chromium_pid=""
cleanup() {
  [[ -n $fixture_pid ]] && { pkill -P "$fixture_pid" 2>/dev/null; kill "$fixture_pid" 2>/dev/null; }
  [[ -n $chromium_pid ]] && pkill -f -- "--user-data-dir=$run/chromium-profile" 2>/dev/null
  # A failed C1/C2 case must not leave the session without its plugin.
  plugin_loaded || nestctl plugin load "$plugin_path" >>"$log" 2>&1
}
trap cleanup EXIT

# "<x> <y> <w> <h> <address>" of the window titled $1 (output-relative position).
win() {
  nestctl clients -j | jq -r --arg t "$1" --argjson mx "$mx" --argjson my "$my" \
    '[.[] | select(.title == $t and .mapped)][0] | select(. != null) | "\(.at[0] - $mx) \(.at[1] - $my) \(.size[0]) \(.size[1]) \(.address)"'
}
wait_win() { local _; for _ in $(seq 1 60); do [[ -n $(win "$1") ]] && return 0; sleep 0.1; done; return 1; }
place() { # <title> <x> <y> (output-relative)
  local a
  a=$(win "$1" | cut -d' ' -f5)
  [[ -n $a ]] && nestctl dispatch "hl.dsp.window.move({ x = $((mx + $2)), y = $((my + $3)), window = 'address:$a' })" >>"$log" 2>&1
}
fixture_out() { cat "$run/tdrag-$case_name.out" 2>/dev/null; }
said() { grep -qx -- "$1" "$run/tdrag-$case_name.out" 2>/dev/null; }
wait_said() { local _; for _ in $(seq 1 50); do said "$1" && return 0; sleep 0.1; done; return 1; }
# A fresh fixture in MODE, its two windows placed; false when it did not get ready.
start_fixture() { # <case name> <mode>
  stop_fixture
  case_name=$1
  env -u DISPLAY -u WAYLAND_DISPLAY DBUS_SESSION_BUS_ADDRESS="$bus" setsid "$root/scripts/dev/isolated.sh" --name "tdrag-$1" -- "$fixture" "$2" \
    >"$run/tdrag-$1.out" 2>>"$log" </dev/null &
  fixture_pid=$!
  wait_said ready || { say "  the fixture did not get ready: $(fixture_out | tr '\n' '|')"; return 1; }
  wait_win gf-tdrag-source && wait_win gf-tdrag-target || return 1
  place gf-tdrag-source 100 200
  place gf-tdrag-target 1000 200
  sleep 0.5
  pointer abs 300 140 sleep 100 # off both windows
}
stop_fixture() {
  [[ -n $fixture_pid ]] || return 0
  pkill -P "$fixture_pid" 2>/dev/null
  kill "$fixture_pid" 2>/dev/null
  wait "$fixture_pid" 2>/dev/null
  fixture_pid=""
  sleep 0.3
}
# The window titled $1 is at x,y (output-relative), 2 px slack.
at_xy() { # <title> <x> <y>
  local x y _w _h _a
  read -r x y _w _h _a < <(win "$1")
  say "  $1 at ${x:-?},${y:-?} (want $2,$3)"
  [[ -n ${x:-} ]] && ((x - $2 <= 2 && $2 - x <= 2 && y - $3 <= 2 && $3 - y <= 2))
}
# The fixture of case $1 printed dnd_drop_performed, then cancelled (the protocol's order for a drop nobody completed).
drop_then_cancel() { awk '/^dnd_drop_performed$/ { d = NR } /^cancelled$/ { c = NR } END { exit !(d && c && d < c) }' "$run/tdrag-$1.out"; }
tile_of() { # <address>: "<state> <place>" of its tile record ("none none" without one)
  nestctl grassfield-tiling 2>>"$log" | jq -r --arg a "${1#0x}" '[.outputs[].windows[] | select(.address == $a)][0] // {} | "\(.state // "none") \(.place // "none")"'
}

say "toplevel_drag: nested pid $hypr_pid, instance $sig, output $out ${mw}x${mh} (logical, scale $mscale) at $mx,$my, free edge: ${side:-none}, other output: ${other_output:-none}"

# ---- T0 ----
check "T0: capabilities list toplevel-drag" bash -c "timeout 10 '$root/scripts/nestctl' -j grassfield 2>/dev/null | jq -e '.features | index(\"toplevel-drag\")' >/dev/null"
if ! start_fixture global tear; then
  check "T0: the fixture starts and sees xdg_toplevel_drag_manager_v1" false
  exit 1
fi
check "T0: the fixture sees xdg_toplevel_drag_manager_v1 version 1" said "global xdg_toplevel_drag_manager_v1 1"

# ---- T1-T3: tear off, follow, enter the target, drop there ----
if start_fixture tear tear; then
  pointer abs 300 350 sleep 200 down sleep 900 drag 600 700 sleep 1500 drag 650 760 sleep 1500 drag 1200 350 sleep 1500 up sleep 300 &
  p=$!
  sleep 0.9 # the press, the drag started, the torn window mapped under the pointer
  check "T1: the drag started and the torn window mapped" wait_said "mapped torn"
  check "T1: the torn window maps under the pointer at the client's offset" at_xy gf-tdrag-torn 260 338
  sleep 1.3 # first drag done
  check "T1: it follows the pointer" at_xy gf-tdrag-torn 560 688
  sleep 1.5
  check "T1: and again" at_xy gf-tdrag-torn 610 748
  sleep 1.5 # over the target now
  check "T2: over the target, the drag enters the target window" said "enter target"
  check "T2: the torn window never becomes the drag's target" bash -c "! grep -qx 'enter torn' '$run/tdrag-tear.out'"
  wait "$p"
  check "T3: released over the target: drop there" wait_said "drop target"
  check "T3: dnd_drop_performed" wait_said "dnd_drop_performed"
  check "T3: dnd_finished (Hyprland completed the drop)" wait_said "dnd_finished"
  check "T3: the client destroys its object after the drag ended (no protocol error)" wait_said "drag object destroyed"
  sleep 0.6
  check "T3: the torn window stays where it was released" at_xy gf-tdrag-torn 1160 338
  torn=$(win gf-tdrag-torn | cut -d' ' -f5)
  tile_untiled() { local t; t=$(tile_of "$torn"); say "  tile record: $t"; [[ $t != tiled* ]]; }
  check "T3: not tiled" tile_untiled
  check_log "T3: the plugin logged the drop" "toplevel drag: window ${torn#0x} dropped: stays where it is" tile_untiled
else
  check "T1: the fixture starts" false
fi

# ---- T1b: Chromium's torn window (its window geometry changes right after its map) stays under the resting pointer ----
if start_fixture geometry geometry; then
  # Low enough that the 980x620 window overhangs the work area's bottom (what made Hyprland fit Chromium's window).
  pointer abs 300 350 sleep 200 down sleep 600 drag 600 560 sleep 1800 up sleep 300 &
  p=$!
  sleep 2.2 # mapped, then its geometry changed, the pointer at rest at 600,560 since about 1 s
  check "T1b: a window whose geometry changes after its map stays under the resting pointer" at_xy gf-tdrag-torn 560 548
  wait "$p"
else
  check "T1b: the fixture starts" false
fi

# ---- T4: tiles at the free edge ----
if [[ -z $side ]]; then
  say "SKIP: T4, T5 (both edges of $out are shared): NOT VERIFIED"
elif start_fixture tile tear; then
  pointer abs 300 350 sleep 200 down sleep 600 drag 900 600 sleep 300 drag "$edge" $((mh / 2)) sleep 1800 up sleep 300
  sleep 1
  torn=$(win gf-tdrag-torn | cut -d' ' -f5)
  check "T4: released over nothing at the edge: Hyprland ended the drag (cancelled or dropped)" bash -c "grep -qxE 'cancelled|dnd_drop_performed' '$run/tdrag-tile.out'"
  # Hyprland 0.56.2 cancels a drop nobody accepted without dnd_drop_performed; Chromium reads a lone cancel as Escape and puts
  # the tab back. The plugin sends dnd_drop_performed first (the user dropped): the protocol's order.
  check "T4: dnd_drop_performed before cancelled (a drop, not a revert)" drop_then_cancel tile
  tiled_side() { local t; t=$(tile_of "$torn"); say "  tile record: $t (want tiled $side)"; [[ $t == "tiled $side" ]]; }
  check "T4: the torn window takes the $side half (tile record)" tiled_side
  check_log "T4: the plugin logged the tile" "toplevel drag: window ${torn#0x} dropped: tiled into the place shown" tiled_side
else
  check "T4: the fixture starts" false
fi

# ---- T5: Escape cancels (no tile) ----
if [[ -n $side ]] && start_fixture escape tear; then
  pointer abs 300 350 sleep 200 down sleep 600 drag 900 600 sleep 300 drag "$edge" $((mh / 2)) sleep 2600 up sleep 300 &
  p=$!
  sleep 2.6 # resting at the edge, the preview shown
  keys tap Escape
  wait "$p"
  sleep 0.8
  torn=$(win gf-tdrag-torn | cut -d' ' -f5)
  check "T5: Escape cancels the drag" said "cancelled"
  check "T5: no dnd_drop_performed (a cancel, the client reverts)" bash -c "! grep -qx 'dnd_drop_performed' '$run/tdrag-escape.out'"
  tile_none() { local t; t=$(tile_of "$torn"); say "  tile record: $t"; [[ $t != tiled* ]]; }
  check "T5: no tile" tile_none
  check_log "T5: the plugin logged the cancel" "toplevel drag: window ${torn#0x} cancelled"
fi

# ---- T6: merge (unmap detaches, attach again follows) ----
if start_fixture merge merge; then
  pointer abs 300 350 sleep 200 down sleep 600 drag 1200 350 sleep 1200 drag 700 750 sleep 1500 drag 760 800 sleep 1200 up sleep 300 &
  p=$!
  sleep 1.6 # over the target since about 0.8 s
  check "T6: over the target the torn window unmaps itself" said "unmapped torn"
  check_log "T6: the plugin detaches it" "unmapped: detached"
  sleep 1.3 # pulled out at about 2.0 s, the pointer at rest at 700,750 until about 3.5 s
  check "T6: pulled out again, it maps again" bash -c "[[ \$(grep -cx 'mapped torn' '$run/tdrag-merge.out') -ge 2 ]]"
  check "T6: and follows the pointer again (at the client's offset)" at_xy gf-tdrag-torn 660 738
  wait "$p"
else
  check "T6: the fixture starts" false
fi

# ---- T7: an existing window attached before start_drag (no jump) ----
if start_fixture existing existing; then
  pointer abs 300 350 sleep 200 down sleep 300 drag 500 500 sleep 1500 up sleep 300 &
  p=$!
  sleep 1.6
  check "T7: the source window itself moves with the pointer, without jumping" at_xy gf-tdrag-source 300 350
  wait "$p"
else
  check "T7: the fixture starts" false
fi

# ---- T8: protocol errors ----
for pair in "attach-twice:xdg_toplevel_drag_v1 0" "destroy-early:xdg_toplevel_drag_v1 1" "source-twice:xdg_toplevel_drag_manager_v1 0" "selection:xdg_toplevel_drag_manager_v1 0"; do
  m=${pair%%:*} want=${pair#*:}
  if start_fixture "$m" "$m"; then
    pointer abs 300 350 sleep 200 down sleep 600 up sleep 300
    check "T8: $m: protocol error $want" wait_said "protocol error $want"
  else
    check "T8: $m: the fixture starts" false
  fi
  check "T8: $m: Hyprland alive" hypr_alive
done
stop_fixture

# ---- T10, T11: a target that finishes late, or never (review of aa8211de) ----
for m in late-finish no-finish; do
  if start_fixture "$m" "$m"; then
    pointer abs 300 350 sleep 200 down sleep 600 drag 1200 350 sleep 1200 up sleep 300
    torn=$(win gf-tdrag-torn | cut -d' ' -f5)
    check "$m: released over the target: drop there" wait_said "drop target"
    check_log "$m: the window's drag ends at the release" "toplevel drag: window ${torn#0x} released: its drag ends here"
    read -r tx ty _ _ _ < <(win gf-tdrag-torn)
    # Counter-review of 2dcae1f2: Hyprland keeps its drag until the target finishes; the torn window, under the pointer and
    # still attached, must never get an enter for its own drag meanwhile.
    pointer abs 1202 350 sleep 200 abs 1204 352 sleep 200
    check "$m: 2 px after the release, the torn window is not the drag's target" bash -c "! grep -qx 'enter torn' '$run/tdrag-$m.out'"
    pointer abs 700 800 sleep 300 abs 760 840 sleep 300 # the pointer moves on while Hyprland waits for the target
    check "$m: the pointer moves on, the window stays where it was released" at_xy gf-tdrag-torn "${tx:-0}" "${ty:-0}"
    if [[ $m == late-finish ]]; then
      check "late-finish: the target finished late" wait_said "finished late"
      check "late-finish: then dnd_drop_performed" wait_said "dnd_drop_performed"
      check "late-finish: the object destroyed after it, no protocol error" bash -c "grep -qx 'drag object destroyed' '$run/tdrag-$m.out' && ! grep -q '^protocol error' '$run/tdrag-$m.out'"
    else
      sleep 3
      check "no-finish: no dnd_drop_performed (the target never finished)" bash -c "! grep -qx 'dnd_drop_performed' '$run/tdrag-$m.out'"
      check "no-finish: Hyprland alive" hypr_alive
      keys tap Escape # Hyprland's own way out of a drag it still holds (abortDndIfPresent)
      sleep 0.5
    fi
  else
    check "$m: the fixture starts" false
  fi
done

# ---- T10b: a target that finishes without receiving (Chromium's tab drag): Hyprland cancels, the plugin's drop comes first ----
if start_fixture finish-only finish-only; then
  pointer abs 300 350 sleep 200 down sleep 600 drag 1200 350 sleep 1200 up sleep 600
  check "finish-only: released over the target: drop there" wait_said "drop target"
  sleep 0.5
  check "finish-only: dnd_drop_performed before Hyprland's cancel" drop_then_cancel finish-only
else
  check "finish-only: the fixture starts" false
fi

# ---- T12, T13: the source or the window's role destroyed mid-drag ----
if start_fixture source-destroy source-destroy; then
  pointer abs 300 350 sleep 200 down sleep 600 drag 600 600 sleep 1800 drag 700 700 sleep 800 up sleep 300 &
  p=$!
  sleep 2.2
  torn=$(win gf-tdrag-torn | cut -d' ' -f5)
  check "source-destroy: the client destroyed the source mid-drag" said "source destroyed"
  check_log "source-destroy: a cancel for the window (logged)" "toplevel drag: window ${torn#0x} cancelled"
  read -r tx ty _ _ _ < <(win gf-tdrag-torn)
  wait "$p"
  check "source-destroy: the window follows no more" at_xy gf-tdrag-torn "${tx:-0}" "${ty:-0}"
  check "source-destroy: no protocol error" bash -c "! grep -q '^protocol error' '$run/tdrag-source-destroy.out'"
  check "source-destroy: Hyprland alive" hypr_alive
else
  check "source-destroy: the fixture starts" false
fi
if start_fixture role-destroy role-destroy; then
  pointer abs 300 350 sleep 200 down sleep 600 drag 600 600 sleep 1800 drag 700 700 sleep 800 up sleep 300 &
  p=$!
  sleep 0.9
  torn=$(win gf-tdrag-torn | cut -d' ' -f5)
  wait "$p"
  check "role-destroy: the client destroyed the torn window's role mid-drag" said "torn role destroyed"
  check_log "role-destroy: detached (logged)" "toplevel drag: window ${torn#0x} unmapped: detached"
  check "role-destroy: the drag ended as Hyprland's own" bash -c "grep -qxE 'cancelled|dnd_drop_performed' '$run/tdrag-role-destroy.out'"
  check "role-destroy: no protocol error" bash -c "! grep -q '^protocol error' '$run/tdrag-role-destroy.out'"
  check "role-destroy: Hyprland alive" hypr_alive
else
  check "role-destroy: the fixture starts" false
fi

# ---- T14: the client killed mid-drag ----
if start_fixture killed tear; then
  log_mark=$(grep -ac "" "$hyprlog" 2>/dev/null || echo 0)
  pointer abs 300 350 sleep 200 down sleep 600 drag 600 600 sleep 1500 drag 700 700 sleep 600 up sleep 300 &
  p=$!
  sleep 1.4 # the torn window follows now
  pkill -9 -P "$fixture_pid" 2>/dev/null; kill -9 "$fixture_pid" 2>/dev/null
  wait "$p"
  fixture_pid=""
  sleep 0.5
  check "killed: Hyprland alive after the client died mid-drag" hypr_alive
  no_exception() { ! tail -n +"$((log_mark + 1))" "$hyprlog" 2>/dev/null | grep -a '\[grassfield\]' | grep -aq 'exception in'; }
  check "killed: no plugin exception" no_exception
else
  check "killed: the fixture starts" false
fi

# ---- T16: a second display ----
if [[ -n $other_output ]]; then
  if start_fixture display tear; then
    timeout 60 "$root/scripts/dev/pointer.sh" output "$out" abs 300 350 sleep 200 down sleep 600 drag 600 600 sleep 300 \
      output "$other_output" drag 200 200 sleep 1200 up sleep 300 >>"$log" 2>&1
    sleep 0.8
    on_other() {
      local id mon
      id=$(nestctl monitors -j | jq -r --arg o "$other_output" '.[] | select(.name == $o) | .id')
      mon=$(nestctl clients -j | jq -r '[.[] | select(.title == "gf-tdrag-torn" and .mapped)][0].monitor // empty')
      say "  torn window on monitor ${mon:-?} (want $id, $other_output)"
      [[ -n $mon && $mon == "$id" ]]
    }
    check "display: dropped on $other_output, the torn window takes that output" on_other
  else
    check "display: the fixture starts" false
  fi
else
  say "SKIP: T16 second display (one output in this nested session): NOT VERIFIED"
fi
stop_fixture

# ---- T9: Chromium (best effort) ----
if command -v chromium >/dev/null && [[ -n $side ]]; then
  dead_proxy=127.0.0.1:9
  rm -rf "$run/chromium-profile"
  http_proxy=http://$dead_proxy https_proxy=http://$dead_proxy all_proxy=http://$dead_proxy no_proxy='' \
    env -u DISPLAY WAYLAND_DISPLAY="$sock" WAYLAND_DEBUG=1 DBUS_SESSION_BUS_ADDRESS="$bus" GDK_BACKEND=wayland setsid "$root/scripts/dev/isolated.sh" --name tdrag-chromium -- \
    chromium --user-data-dir="$run/chromium-profile" --no-first-run --no-default-browser-check --password-store=basic --disable-background-networking \
    --disable-component-update --disable-sync --proxy-server="$dead_proxy" --ozone-platform=wayland --window-size=1000,640 about:blank about:blank \
    >>"$run/chromium.out" 2>&1 </dev/null &
  chromium_pid=$!
  # WAYLAND_DEBUG=1 (set on the launch above) writes Chromium's protocol trace to chromium.out: the drag's
  # wl_data_source.dnd_drop_performed / cancelled order is read there when T9 fails.
  chromes() { nestctl clients -j | jq -r --argjson mx "$mx" --argjson my "$my" '[.[] | select(.class == "chromium" and .mapped)] | .[] | "\(.at[0] - $mx) \(.at[1] - $my) \(.size[0]) \(.size[1]) \(.address)"'; }
  for _ in $(seq 1 80); do [[ -n $(chromes) ]] && break; sleep 0.25; done
  read -r _ _ _ _ caddr < <(chromes | head -n 1)
  if [[ -n ${caddr:-} ]]; then
    sleep 2
    nestctl dispatch "hl.dsp.window.move({ x = $((mx + 200)), y = $((my + 200)), window = 'address:$caddr' })" >>"$log" 2>&1
    sleep 0.8
    # The second tab: right of the first one (Chromium 155: tabs of about 240 px from about 80 px in, on an 18 px high row).
    pointer abs 470 218 sleep 150 click sleep 500
    pointer abs 470 218 sleep 200 down sleep 200 drag 480 420 sleep 800 drag 700 520 sleep 1200 drag 760 560 sleep 1200 drag "$edge" $((mh / 2)) sleep 1800 up sleep 400 &
    p=$!
    sleep 2.4
    second=$(chromes | awk -v a="$caddr" '$5 != a' | head -n 1)
    if [[ -n $second ]]; then
      read -r sx0 sy0 _ _ saddr <<<"$second"
      sleep 1.2
      read -r sx1 sy1 _ _ _ < <(chromes | awk -v a="$saddr" '$5 == a')
      say "  chromium torn window at $sx0,$sy0 then ${sx1:-?},${sy1:-?} (the pointer moved by 60,40)"
      follows() { [[ -n ${sx1:-} ]] && (( sx1 - sx0 >= 50 && sx1 - sx0 <= 70 && sy1 - sy0 >= 30 && sy1 - sy0 <= 50 )); }
      check "T9: chromium: the torn-off tab's window follows the pointer" follows
      wait "$p"
      sleep 1
      chrome_tiled() { local t; t=$(tile_of "$saddr"); say "  tile record: $t (want tiled $side)"; [[ $t == "tiled $side" ]]; }
      check "T9: chromium: released at the free edge, it tiles" chrome_tiled
    else
      wait "$p"
      say "NOT VERIFIED: T9 chromium: no second window came off (the tab may not be where this script presses: $(chromes | wc -l) window(s))"
    fi
  else
    say "NOT VERIFIED: T9 chromium did not map"
  fi
  pkill -f -- "--user-data-dir=$run/chromium-profile" 2>/dev/null
  chromium_pid=""
else
  say "SKIP: T9 chromium (not installed or no free edge): NOT VERIFIED here"
fi

# ---- C1/C2: unload during a drag, load again ----
if ((c1)); then
  if start_fixture c1 tear; then
    pointer abs 300 350 sleep 200 down sleep 600 drag 600 600 sleep 3500 drag 700 650 sleep 600 up sleep 300 &
    p=$!
    sleep 1.8 # the torn window follows now
    nestctl plugin unload "$plugin_path" >>"$log" 2>&1
    wait "$p"
    sleep 0.5
    check "C1: Hyprland alive after the unload during the drag" hypr_alive
    check "C1: the drag ended as Hyprland's own (cancelled or dropped)" bash -c "grep -qxE 'cancelled|dnd_drop_performed' '$run/tdrag-c1.out'"
    check "C1: the fixture got no protocol error" bash -c "! grep -q '^protocol error' '$run/tdrag-c1.out'"
    stop_fixture
    case_name=c2-off
    env -u DISPLAY -u WAYLAND_DISPLAY DBUS_SESSION_BUS_ADDRESS="$bus" setsid "$root/scripts/dev/isolated.sh" --name tdrag-c2-off -- "$fixture" tear \
      >"$run/tdrag-c2-off.out" 2>>"$log" </dev/null &
    fixture_pid=$!
    check "C2: without the plugin no global (Chromium as before)" wait_said "no xdg_toplevel_drag_manager_v1"
    stop_fixture
    nestctl plugin load "$plugin_path" >>"$log" 2>&1
    sleep 1
    check "C2: the plugin loads again" plugin_loaded
    if start_fixture c2-on tear; then
      check "C2: loaded again, the global is back" said "global xdg_toplevel_drag_manager_v1 1"
    else
      check "C2: loaded again, a fixture starts" false
    fi
    stop_fixture
  else
    check "C1: the fixture starts" false
  fi
fi

stop_fixture
check "Hyprland alive at the end" hypr_alive
if ((fail)); then
  say "toplevel_drag: FAIL (log: $log)"
  exit 1
fi
say "toplevel_drag: PASS (log: $log)"
exit 0
