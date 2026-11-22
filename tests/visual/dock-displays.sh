#!/usr/bin/env bash
# The Dock on every display and its scope (owner report 2026-11-22, three displays: auto-hide took effect on one display only and the
# glass was missing on the others). The nested session has two outputs: GF-REF (headless, run at scale 1.25 with --ref-scale, like
# the owner's panel) and the nested window output. Checked, on the shell's real state (`dock hidestate`, `dock iconsurface`):
#   1. dock.allDisplays on (the default): a Dock is shown on BOTH outputs, with the same glass tint alpha;
#   2. Automatically hide on in "All Displays" (the global key): both outputs hide;
#   3. an override for one output (dock.outputs, autohide false) keeps that output's Dock shown while the other hides;
#   4. the override removed: both hide again; autohide off again: both shown;
#   5. dock.allDisplays off (macOS): one output only has the Dock, the other is hidden.
# Screenshots of both outputs are kept in .dev/visual/dock-displays/.
# Run as a BARE command (reference machine only). The nested session this script starts is torn down on exit.
#   tests/visual/dock-displays.sh
# Exit status 1 when a check fails.
source "$(dirname "$0")/lib.sh"
set +e

was_running=0
vs_nested_running && was_running=1
cleanup() {
  vs_nested_running && vs_kill_clients || true
  (( was_running )) || "$VS_ROOT/scripts/dev/nested-down.sh" >/dev/null 2>&1 || true
  return 0
}
trap cleanup EXIT
trap 'exit 130' INT TERM

fails=0
pass() { echo "PASS: $*"; }
fail() { fails=$((fails + 1)); echo "FAIL: $*"; }

out=$VS_STATE/dock-displays
mkdir -p "$out"
vs_session en || { echo "dock-displays: the nested session did not come up"; exit 2; }
vs_reset dark 0.25
cfg=$VS_DEV/config/grassfield.json

mapfile -t outputs < <("$VS_ROOT/scripts/nestctl" monitors -j | jq -r '.[].name')
echo "dock-displays: outputs ${outputs[*]}"
(( ${#outputs[@]} >= 2 )) || { echo "dock-displays: needs two outputs, found ${#outputs[@]}"; exit 2; }
scales=$("$VS_ROOT/scripts/nestctl" monitors -j | jq -r '.[] | "\(.name)=\(.scale)"' | tr '\n' ' ')
echo "dock-displays: scales $scales"
a=${outputs[0]}
b=${outputs[1]}

# edit KEY=JSON... : sets keys of the settings of this tree (the shell follows the file), then waits for it to settle.
edit() {
  jq "$1" "$cfg" > "$cfg.new" 2>/dev/null && mv "$cfg.new" "$cfg" || { echo "dock-displays: cannot edit $cfg"; exit 2; }
  sleep 3
}
state() { vs_ipc dock hidestate "$1" | awk '{print $1}'; }
want() { # NAME OUTPUT STATE
  local got
  got=$(state "$2")
  if [[ $got == "$3" ]]; then pass "$1: $2 is $3"; else fail "$1: $2 is '$got', expected $3"; fi
}
shot() { # NAME
  local o
  for o in "$a" "$b"; do
    "$VS_ROOT/scripts/dev/shot.sh" "dock-displays-$1-$o" "$o" >/dev/null 2>&1 && cp "$VS_DEV/shots/dock-displays-$1-$o.png" "$out/$1-$o.png"
  done
}

# 1. Defaults: a Dock on each output, the same glass.
edit '.dock.autohide = false | .dock.allDisplays = true | .dock.outputs = []'
want default "$a" shown
want default "$b" shown
shot default
alphas=$(vs_ipc dock iconsurface | jq -r '[.[].alpha] | unique | length')
echo "dock-displays: iconsurface $(vs_ipc dock iconsurface)"
[[ $alphas == 1 ]] && pass "the glass tint alpha is the same on every output" || fail "the glass tint alpha differs between outputs"

# 2. Auto-hide for All Displays reaches both.
edit '.dock.autohide = true'
want autohide-all "$a" hidden
want autohide-all "$b" hidden

# 3. One output with its own setting.
edit ".dock.outputs = [{display: {name: \"$b\", model: \"\", serial: \"\"}, autohide: false}]"
want override "$a" hidden
want override "$b" shown
shot override

# 4. The override removed, then auto-hide off.
edit '.dock.outputs = []'
want cleared "$a" hidden
want cleared "$b" hidden
edit '.dock.autohide = false'
want off "$a" shown
want off "$b" shown

# 5. The macOS model: one Dock.
edit '.dock.allDisplays = false'
shown=0
for o in "$a" "$b"; do [[ $(state "$o") == shown ]] && shown=$((shown + 1)); done
[[ $shown == 1 ]] && pass "allDisplays off: one output has the Dock" || fail "allDisplays off: $shown outputs show the Dock"
shot single
edit '.dock.allDisplays = true'

echo "dock-displays: $fails failure(s); screenshots in $out"
exit $(( fails > 0 ))
