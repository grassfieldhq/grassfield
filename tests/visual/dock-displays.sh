#!/usr/bin/env bash
# The Dock on every display and its scope (owner report 2026-11-22, three displays: auto-hide took effect on one display only and the
# glass was missing on the others). The nested session has two outputs: GF-REF (headless, run at scale 1.25 like the owner's panel)
# and the nested window output. Checked on the shell's real state (`dock hidestate`, `dock iconsurface`) AND on the pixels of each
# output's Dock strip (a capture with the Dock shown differs from one with it hidden, where one is expected):
#   0. GF-REF runs at scale 1.25;
#   1. dock.allDisplays on (the default): a Dock is shown on BOTH outputs, with the same glass tint alpha;
#   2. Automatically hide on in "All Displays" (the global key): both outputs hide, and no Dock is drawn on either;
#   3. an override for one output (dock.outputs, autohide false) keeps that output's Dock shown and drawn while the other hides;
#   4. the override removed: both hide again; autohide off again: both shown;
#   5. dock.allDisplays off (macOS): one output only has the Dock, the other is hidden.
# Screenshots of both outputs are kept in .dev/visual/dock-displays/.
# Run as a BARE command (reference machine only). The nested session this script starts is torn down on exit; a session that is
# already running keeps its own scale, so stop it first.
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
# GF-REF at the owner's panel scale (nested-up reads GRASSFIELD_REF_SCALE).
export GRASSFIELD_REF_SCALE=1.25
vs_session en || { echo "dock-displays: the nested session did not come up"; exit 2; }
vs_reset dark 0.25
cfg=$VS_DEV/config/grassfield.json

mapfile -t outputs < <("$VS_ROOT/scripts/nestctl" monitors -j | jq -r '.[].name')
echo "dock-displays: outputs ${outputs[*]}"
(( ${#outputs[@]} >= 2 )) || { echo "dock-displays: needs two outputs, found ${#outputs[@]}"; exit 2; }
a=${outputs[0]}
b=${outputs[1]}
ref_scale=$("$VS_ROOT/scripts/nestctl" monitors -j | jq -r '.[] | select(.name == "GF-REF") | .scale')
echo "dock-displays: GF-REF scale $ref_scale"
[[ $ref_scale == 1.25 ]] && pass "GF-REF runs at scale 1.25" || fail "GF-REF runs at scale $ref_scale, expected 1.25 (a session that was already running keeps its scale: stop it first)"

# edit JQ-FILTER: changes the settings of this tree (the shell follows the file), then waits for it to settle.
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
shot() { # NAME: both outputs → $out/NAME-OUTPUT.png
  local o
  for o in "$a" "$b"; do
    # A capture of the nested window output waits for the host to repaint that window: bounded, so a host that does not
    # (another workspace) fails the pixel check below instead of hanging the run.
    rm -f "$VS_DEV/shots/dock-displays-$1-$o.png" "$out/$1-$o.png"
    timeout 20 "$VS_ROOT/scripts/dev/shot.sh" "dock-displays-$1-$o" "$o" >/dev/null 2>&1 && cp "$VS_DEV/shots/dock-displays-$1-$o.png" "$out/$1-$o.png"
  done
}
# differ A B OUTPUT: pixels of the Dock's strip (bottom centre of the output) that differ between two captures (-1: no capture).
differ() {
  local ca=$out/$1-$3.png cb=$out/$2-$3.png d
  [[ -s $ca && -s $cb ]] || { echo -1; return; }
  magick "$ca" -gravity south -crop 40%x16%+0+0 +repage "$out/.a.png"
  magick "$cb" -gravity south -crop 40%x16%+0+0 +repage "$out/.b.png"
  d=$(magick compare -metric AE -fuzz 8% "$out/.a.png" "$out/.b.png" null: 2>&1 | awk '{print int($1)}')
  echo "${d:--1}"
}
# drawn NAME SHOWN-CAPTURE OUTPUT yes|no: the Dock is (not) in the pixels, against the capture of the same output with every Dock hidden.
drawn() {
  local n
  n=$(differ "$2" hidden "$3")
  # No capture: the nested window output is repainted only while the host shows that window (grim waits for it, bounded above).
  # The IPC state is still checked; the pixels of that output are NOT VERIFIED, said plainly and not a pass.
  if (( n < 0 )); then
    echo "NOT VERIFIED: $1: no capture of $3 (the host did not repaint the nested window), only its IPC state is checked"
    return
  fi
  if [[ $4 == yes ]]; then
    (( n > 400 )) && pass "$1: $3 draws a Dock ($n px of its strip differ from the hidden capture)" || fail "$1: $3 draws no Dock ($n px differ from the hidden capture)"
  else
    (( n >= 0 && n <= 400 )) && pass "$1: $3 draws no Dock ($n px differ)" || fail "$1: $3 draws a Dock ($n px differ from the hidden capture)"
  fi
}

# 2 first, for the reference: every Dock hidden.
edit '.dock.autohide = true | .dock.allDisplays = true | .dock.outputs = []'
want autohide-all "$a" hidden
want autohide-all "$b" hidden
shot hidden

# 1. Defaults: a Dock on each output, the same glass, drawn.
edit '.dock.autohide = false | .dock.allDisplays = true | .dock.outputs = []'
want default "$a" shown
want default "$b" shown
shot default
drawn default default "$a" yes
drawn default default "$b" yes
echo "dock-displays: iconsurface $(vs_ipc dock iconsurface)"
alphas=$(vs_ipc dock iconsurface | jq -r '[.[].alpha] | unique | length')
[[ $alphas == 1 ]] && pass "the glass tint alpha is the same on every output" || fail "the glass tint alpha differs between outputs"

# 3. One output with its own setting: auto-hide on for all, off for b.
edit ".dock.autohide = true | .dock.outputs = [{display: {name: \"$b\", model: \"\", serial: \"\"}, autohide: false}]"
want override "$a" hidden
want override "$b" shown
shot override
drawn override override "$a" no
drawn override override "$b" yes

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
n_a=$(differ single hidden "$a")
n_b=$(differ single hidden "$b")
if (( n_a < 0 || n_b < 0 )); then
  echo "NOT VERIFIED: allDisplays off: an output has no capture ($a $n_a px, $b $n_b px); the IPC state above is the evidence"
elif { (( n_a > 400 )) && (( n_b <= 400 )); } || { (( n_b > 400 )) && (( n_a <= 400 )); }; then
  pass "allDisplays off: a Dock is drawn on one output only ($a $n_a px, $b $n_b px)"
else
  fail "allDisplays off: the Dock is not drawn on exactly one output ($a $n_a px, $b $n_b px)"
fi
edit '.dock.allDisplays = true'
rm -f "$out/.a.png" "$out/.b.png"

echo "dock-displays: $fails failure(s); screenshots in $out"
exit $(( fails > 0 ))
