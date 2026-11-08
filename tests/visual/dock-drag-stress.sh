#!/usr/bin/env bash
# Stress test of the Dock drag: the pinned foot tile is never lost by a drag that comes back into the shelf before the release.
# Repeats the pattern of the contrast harness (press the pinned tile, drag far above the shelf so "Remove" shows, hold, drag back
# onto its slot, release) N times, in three variants: plain, a window opening during the drag (the rebuild waits for the release),
# and a very short hold. After every iteration the live pinned list (qs ipc: dock pinned) must still be ["foot"]. A last drag that
# is released far above the Dock must remove the tile: it proves the pointer really drives the drag.
# Interruptions: while the tile is held out of the Dock, something else takes over (Search, Overview, Apps, the app switcher, the
# Dock menu, a banner, an output added then removed, an app quitting); the pointer then comes back and releases on the slot. A
# tile is removed only by a real release outside the Dock, so the pins must be unchanged after each of them (5 times each).
# Run as a BARE command (reference machine only). The nested session this script starts is torn down on exit.
#   tests/visual/dock-drag-stress.sh [ITERATIONS=50] [INTERRUPT-ROUNDS=5] ["trigger ..."]
# Exit status 1 when the pinned list changed (the iteration is named) or the control drag did not remove the tile.
source "$(dirname "$0")/lib.sh"

n=${1:-50}
was_running=0
vs_nested_running && was_running=1
cleanup() {
  [[ -n ${ptr_pid:-} ]] && kill "$ptr_pid" 2>/dev/null || true
  vs_nested_running && vs_kill_clients || true
  (( was_running )) || "$VS_ROOT/scripts/dev/nested-down.sh" >/dev/null 2>&1 || true
  return 0
}
trap cleanup EXIT
trap 'exit 130' INT TERM

vs_session en
vs_reset dark 0.25
FOOT_X=${FOOT_X:-927} DOCK_Y=1032 UP_Y=900
cfg=$VS_DEV/config/grassfield.json

# Same tiles as the contrast harness: pinned foot, then the two running test apps.
vs_spawn foot --app-id gfdockA
vs_sleep 1.5
vs_spawn foot --app-id gfdockB
vs_sleep 3
vs_park

pinned() { vs_ipc dock pinned | tr -d ' '; }
want='["foot"]'
[[ $(pinned) == "$want" ]] || { echo "dock-drag-stress: start state is $(pinned), not $want" >&2; exit 1; }

fail=0
lost=0
for i in $(seq 1 "$n"); do
  case $(( i % 3 )) in
    0) hold=100 ;;
    1) hold=500 ;;
    *) hold=1500 ;;
  esac
  with_window=$(( i % 5 == 0 ))
  vs_pointer abs $FOOT_X $DOCK_Y sleep 200 down sleep 200 drag $FOOT_X $UP_Y sleep "$hold" drag $FOOT_X $DOCK_Y sleep 100 up sleep 100 abs "$VS_PARK_X" "$VS_PARK_Y" >/dev/null &
  ptr_pid=$!
  if (( with_window )); then
    # A window opens while the tile is held out: the rebuild must wait for the release and must not touch the pin.
    sleep 0.9
    vs_spawn foot --app-id gfstress
  fi
  wait "$ptr_pid" || true
  ptr_pid=""
  sleep 0.6
  got=$(pinned)
  if [[ $got != "$want" ]]; then
    echo "iteration $i (hold ${hold} ms, window during drag: $with_window): pinned is $got"
    fail=1
    lost=$(( lost + 1 ))
    break
  fi
  if (( with_window )); then
    for pid in $("$VS_ROOT/scripts/nestctl" clients -j | jq -r '.[] | select(.class == "gfstress") | .pid'); do
      dev_may_signal "$pid" && kill "$pid" || true
    done
    sleep 1.5
    [[ $(pinned) == "$want" ]] || { echo "iteration $i: pinned changed after the window closed: $(pinned)"; fail=1; break; }
  fi
done
echo "drags: $i, pinned changed: $lost (live list: $(pinned))"
[[ $(jq -c '.dock.pinned' "$cfg") == "$want" ]] || { echo "config file dock.pinned is $(jq -c '.dock.pinned' "$cfg")"; fail=1; }

# Interruptions during a held drag-out (nested only). ROUNDS (2nd argument, default 5) per trigger; 3rd argument: the triggers to run.
rounds=${2:-5}
bus() { cat "$VS_DEV/bus.address"; }
kill_class() {
  local pid
  for pid in $("$VS_ROOT/scripts/nestctl" clients -j | jq -r --arg c "$1" '.[] | select(.class == $c) | .pid'); do
    dev_may_signal "$pid" && kill "$pid" || true
  done
}
# trial NAME CLEANUP-FUNCTION TRIGGER-FUNCTION: hold the tile out, run the trigger, release on the slot, assert the pins.
trial() {
  local name=$1 after=$2 trigger=$3
  "$VS_ROOT/scripts/dev/pointer.sh" output "$VS_OUTPUT" abs $FOOT_X $DOCK_Y sleep 200 down sleep 200 drag $FOOT_X $UP_Y sleep 3000 drag $FOOT_X $DOCK_Y sleep 150 up sleep 150 abs "$VS_PARK_X" "$VS_PARK_Y" >/dev/null &
  ptr_pid=$!
  sleep 1.5
  "$trigger" >/dev/null 2>&1 || true
  sleep 0.6
  wait "$ptr_pid" || true
  ptr_pid=""
  sleep 1.2
  local got; got=$(pinned)
  if [[ $got != "$want" ]]; then
    echo "interruption $name: pinned is $got"
    return 1
  fi
  "$after" >/dev/null 2>&1 || true
  [[ $(pinned) == "$want" ]] || { echo "interruption $name: pinned changed in cleanup: $(pinned)"; return 1; }
}
trig_overview() { vs_ipc overview open; }
end_overview() { vs_ipc overview close; sleep 1.5; }
trig_apps() { vs_ipc apps open; }
end_apps() { vs_ipc apps close; sleep 1.5; }
trig_search() { vs_ipc search open files; }
end_search() { vs_ipc search close; sleep 1; }
trig_switcher() { vs_ipc switcher next ""; }
end_switcher() { vs_ipc switcher cancel; sleep 1; }
trig_dockmenu() { vs_ipc dock menu "$(vs_ipc dock tiles | jq 'index("foot")')" GF-REF; } # the pinned foot tile by its key: the index moves with the fixed tiles
end_dockmenu() { vs_ipc menubar close; sleep 1; }
trig_banner() { DBUS_SESSION_BUS_ADDRESS=$(bus) notify-send -a gfdockB -t 4000 Interrupt "Banner during a drag"; }
end_banner() { sleep 4.5; }
trig_hotplugadd() { "$VS_ROOT/scripts/nestctl" output create headless GF-HOT; }
end_hotplugadd() { "$VS_ROOT/scripts/nestctl" output remove GF-HOT; sleep 1; }
trig_hotplugremove() { "$VS_ROOT/scripts/nestctl" output remove GF-HOT; }
end_hotplugremove() { sleep 1; }
trig_appquit() { kill_class gfdockB; }
end_appquit() { vs_spawn foot --app-id gfdockB; sleep 3; }
ints=0
for name in ${3:-overview apps search switcher dockmenu banner hotplugadd hotplugremove appquit}; do
  for r in $(seq 1 "$rounds"); do
    ints=$(( ints + 1 ))
    # Removal needs the output the previous step created.
    if [[ $name == hotplugremove ]]; then "$VS_ROOT/scripts/nestctl" output create headless GF-HOT >/dev/null 2>&1 || true; sleep 1; fi
    if ! trial "$name (round $r)" "end_$name" "trig_$name"; then
      fail=1
      break 2
    fi
  done
done
"$VS_ROOT/scripts/nestctl" output remove GF-HOT >/dev/null 2>&1 || true
echo "interruptions: $ints trials, pins $([[ $(pinned) == "$want" ]] && echo unchanged || echo CHANGED: $(pinned))"

# Control: released far above the Dock, the (not running) pinned tile is removed. Needs foot with no window: the test apps are
# not foot, so it has none.
sleep 3
vs_pointer abs $FOOT_X $DOCK_Y sleep 200 down sleep 200 drag $FOOT_X $UP_Y sleep 3000 up sleep 200 abs "$VS_PARK_X" "$VS_PARK_Y" >/dev/null &
ptr_pid=$!
sleep 2
"$VS_ROOT/scripts/dev/shot.sh" dock-drag-stress-control "$VS_OUTPUT" >/dev/null
wait "$ptr_pid" || true
ptr_pid=""
sleep 1
if [[ $(pinned) == "[]" ]]; then
  echo "control: released above the Dock removes the tile: ok"
else
  echo "control: released above the Dock left pinned = $(pinned) (the drag did not engage; see $VS_DEV/shots/dock-drag-stress-control.png)"
  fail=1
fi

# Running app (owner report 2026-11-08: foot could not be removed while it ran; macOS allows it): kept again and started with its
# own app id, the tile dragged out and released far above the Dock is unpinned (the file and the live list), and the tile stays
# with its window until the app quits.
jq '.dock.pinned = ["foot"]' "$cfg" >"$cfg.new" && mv "$cfg.new" "$cfg"
sleep 2
vs_spawn foot
sleep 3
vs_park
[[ $(pinned) == "$want" ]] || { echo "running removal: could not keep foot again: $(pinned)"; fail=1; }
vs_pointer abs $FOOT_X $DOCK_Y sleep 200 down sleep 200 drag $FOOT_X $UP_Y sleep 1500 up sleep 200 abs "$VS_PARK_X" "$VS_PARK_Y" >/dev/null
sleep 1.5
if [[ $(pinned) == "[]" && $(jq -c '.dock.pinned' "$cfg") == "[]" ]]; then
  echo "running app: released above the Dock unpins it: ok"
else
  echo "running app: pinned is $(pinned), file $(jq -c '.dock.pinned' "$cfg") (a running app must be removable)"
  fail=1
fi
if [[ $(vs_ipc dock tiles | jq 'index("foot")') == "null" ]]; then
  echo "running app: its tile is gone while it still runs"
  fail=1
else
  echo "running app: the tile stays with its window: ok"
fi
exit $fail
