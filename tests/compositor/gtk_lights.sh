#!/usr/bin/env bash
# L1 nested scenario (ADR-0015 amendment 2026-11-04): the generated GTK themes (ui/tools/gen-gtk-themes.py) draw the title buttons
# of a GTK 3 and a GTK 4 header bar as the plugin's own traffic lights. A foot window with the plugin's titlebar is the
# reference; tests/fixtures/gtk-headerbar.py (GTK 3, GTK 4 without libadwaita) takes the app id of a third-party-list entry
# (org.gnome.Evince: tagged client chrome, no plugin bar) and the theme through GTK_THEME. Measured on the captures, in device
# pixels (tests/compositor/gtk_lights_measure.py): the disc of each light, the first centre and the pitch against the plugin's,
# no glyph with the pointer away, the glyph under the pointer (GTK 3 on the hovered light, GTK 4 on all three: GTK 3 never
# sets :hover on the box that holds the buttons), grey when the window is not active, darker while pressed.
#
# Usage: tests/compositor/gtk_lights.sh [--light|--dark]   (the theme variant the GTK clients get; default light: the plugin's
# own lights are the same colours in both, the grey of an inactive window differs)
# NESTED only, bare: needs scripts/dev/nested-up.sh with the plugin and its private bus (.dev/bus.address), best at
# `--ref-scale 1.25`. Clients start through scripts/dev/isolated.sh (isolated homes, the themes generated into the isolated
# XDG_DATA_HOME), on the nested socket and the private bus. Captures: .dev/gtk-lights/*.png and the measures *.json.
# Exit: 0 PASS (every measure), 1 FAIL, 2 usage or environment error. The pictures still need a look.
set -uo pipefail

root=$(git -C "$(dirname "$0")" rev-parse --show-toplevel)
dev=$root/.dev
out=${GTL_OUTPUT:-GF-REF}
tokens=$root/ui/tokens/tokens.json
measure=$root/tests/compositor/gtk_lights_measure.py

# shellcheck source=../../scripts/dev/pidfile.sh
. "$root/scripts/dev/pidfile.sh"
# shellcheck source=titlebar_geometry.sh
. "$root/tests/compositor/titlebar_geometry.sh" || exit 2
dev_nested_target "$dev" || exit 2
sock=$DEV_NESTED_SOCK
bus=$(cat "$dev/bus.address" 2>/dev/null || true)
case $bus in
  unix:path=/tmp/dbus-*) ;;
  *) echo "gtk_lights: no private bus (.dev/bus.address; nested-up.sh starts it)" >&2; exit 2 ;;
esac

work=$dev/gtk-lights
rm -rf "$work" "$dev/isolated/gtl"
mkdir -p "$work" "$dev/isolated/gtl/data/themes"
python3 -I "$root/ui/tools/gen-gtk-themes.py" "$dev/isolated/gtl/data/themes" >/dev/null || { echo "gtk_lights: the themes did not generate" >&2; exit 2; }
log=$work/run.log
say() { printf '%s %s\n' "$(date '+%H:%M:%S')" "$*" | tee -a "$log"; }
ctl() { timeout 10 "$root/scripts/nestctl" "$@"; }
pointer() { timeout 30 "$root/scripts/dev/pointer.sh" output "$out" "$@" >>"$log" 2>&1; }
client_run() { # <name> <command...>: isolated, on the nested socket and the private bus
  local name=$1; shift
  WAYLAND_DISPLAY=$sock DBUS_SESSION_BUS_ADDRESS=$bus GDK_BACKEND=wayland setsid "$root/scripts/dev/isolated.sh" --name gtl -- "$@" >>"$log" 2>&1 </dev/null &
  echo $!
}

read -r mon_x mon_y mon_w mon_h scale < <(ctl monitors -j | jq -r --arg o "$out" '.[] | select(.name == $o) | "\(.x) \(.y) \(.width) \(.height) \(.scale)"')
[[ -n ${mon_w:-} ]] || { echo "gtk_lights: output $out not found" >&2; exit 2; }
ctl -j plugin list | jq -e '[.[]? | select(.name == "grassfield-compositor")] | length > 0' >/dev/null \
  || { echo "gtk_lights: the plugin is not loaded" >&2; exit 2; }
printf '{"scale": %s}\n' "$scale" >"$work/scale.json"
dev_px() { awk -v s="$scale" -v v="$1" 'BEGIN { printf "%d", v * s + 0.5 }'; }  # logical to device px

pids=()
"$root/scripts/dev/pointer.sh" output "$out" sleep 3600000 >>"$log" 2>&1 &
pids+=($!)
cleanup() { local p; for p in "${pids[@]}"; do pkill -P "$p" 2>/dev/null; kill "$p" 2>/dev/null; done; }
trap cleanup EXIT
fail=0

client() { ctl clients -j | jq -r --arg c "$1" ".[] | select(.class | test(\$c)) | $2" | head -1; }
wait_mapped() { local i; for i in $(seq 1 ${2:-80}); do [[ -n $(client "$1" .address) ]] && return 0; sleep 0.25; done; return 1; }
wait_gone() { local i; for i in $(seq 1 40); do [[ -z $(client "$1" .address) ]] && return 0; sleep 0.25; done; return 1; }
place() { # <class regex> <x> <y> (logical px on the output)
  ctl dispatch "hl.dsp.window.move({ x = $((mon_x + $2)), y = $((mon_y + $3)), window = 'address:$(client "$1" .address)' })" >>"$log" 2>&1
  sleep 0.8
}
away() { pointer abs $((mon_w * 4 / 5)) $((mon_h * 4 / 5)) sleep 300; }  # the pointer rests away from every window
shot() { WAYLAND_DISPLAY=$sock timeout 10 grim -o "$out" "$1" 2>>"$log"; }
# Measure the lights of a capture: <case> <png> <top-left x> <y> (logical px of the crop's corner)
measure_case() {
  python3 -I "$measure" lights "$2" "$(dev_px "$3")" "$(dev_px "$4")" 300 70 "$tokens" "$appearance" >"$work/$1.json" 2>>"$log"
  say "  $1: $(jq -c . "$work/$1.json")"
}

appearance=light
case ${1:-} in --dark) appearance=dark ;; --light|"") ;; *) echo "usage: gtk_lights.sh [--light|--dark]" >&2; exit 2 ;; esac
stop_app() { pkill -P "$1" 2>/dev/null; kill "$1" 2>/dev/null; wait_gone "$2" || say "  ($2 still mapped after the stop)"; }

# --- the plugin's own lights: a foot window, its titlebar above the surface at (160,140)
say "gtk_lights: output $out ${mon_w}x${mon_h} at scale $scale, bus $bus"
p=$(client_run foot foot --window-size-pixels=640x300); pids+=("$p")
wait_mapped '^foot$' || { say "setup error: foot did not map"; exit 2; }
place '^foot$' 160 140
away
shot "$work/foot-active.png"
say "  appearance $appearance"
measure_case foot-active "$work/foot-active.png" 160 $((140 - GF_TB_HEIGHT))
read -r hx hy < <(jq -r '"\(.close.cx) \(.close.cy)"' "$work/foot-active.json")
hover_x=$((160 + $(awk -v v="$hx" -v s="$scale" 'BEGIN { printf "%d", v / s }'))) hover_y=$((140 - GF_TB_HEIGHT + $(awk -v v="$hy" -v s="$scale" 'BEGIN { printf "%d", v / s }')))
pointer abs $((mon_w * 4 / 5)) $((mon_h / 2)) sleep 150
pointer abs $((hover_x - 3)) $((hover_y - 2)) sleep 150
pointer abs "$hover_x" "$hover_y" sleep 600
shot "$work/foot-hover.png"
measure_case foot-hover "$work/foot-hover.png" 160 $((140 - GF_TB_HEIGHT))
stop_app "$p" '^foot$'

theme=Grassfield-multicolor
[[ $appearance == dark ]] && theme=$theme-dark

# One window at (160,140) in the states a light has: active, hovered; with <full> also pressed and inactive.
# <label> <class regex> <full 0|1> <command...>
states() {
  local label=$1 cls=$2 full=$3 p q hx hy hover_x hover_y
  shift 3
  say "$label (theme $theme)"
  p=$(client_run "$label" env GTK_THEME="$theme" "$@"); pids+=("$p")
  if ! wait_mapped "$cls" 160; then say "  FAIL: $label did not map"; fail=1; stop_app "$p" "$cls"; return; fi
  place "$cls" 160 140
  sleep 2
  away
  shot "$work/$label-active.png"
  measure_case "$label-active" "$work/$label-active.png" 160 140
  read -r hx hy < <(jq -r '"\(.close.cx // 0) \(.close.cy // 0)"' "$work/$label-active.json")
  hover_x=$((160 + $(awk -v v="$hx" -v s="$scale" 'BEGIN { printf "%d", v / s }'))) hover_y=$((140 + $(awk -v v="$hy" -v s="$scale" 'BEGIN { printf "%d", v / s }')))
  pointer abs $((mon_w * 4 / 5)) $((mon_h / 2)) sleep 150
  pointer abs $((hover_x - 3)) $((hover_y - 2)) sleep 150
  pointer abs "$hover_x" "$hover_y" sleep 700
  shot "$work/$label-hover.png"
  measure_case "$label-hover" "$work/$label-hover.png" 160 140
  if ((full)); then
    # Pressed: the button held, then the pointer leaves before the release (a release over it would close the window).
    (pointer abs "$hover_x" "$hover_y" sleep 300 down sleep 2500 abs $((hover_x + 140)) $((hover_y + 100)) sleep 100 up) &
    pids+=($!)
    sleep 1.6
    shot "$work/$label-pressed.png"
    measure_case "$label-pressed" "$work/$label-pressed.png" 160 140
    wait "${pids[-1]}" 2>/dev/null
    # Inactive: another window takes the focus.
    q=$(client_run foot foot --window-size-pixels=400x240); pids+=("$q")
    wait_mapped '^foot$' && place '^foot$' 900 420
    away
    shot "$work/$label-inactive.png"
    measure_case "$label-inactive" "$work/$label-inactive.png" 160 140
    stop_app "$q" '^foot$'
  fi
  stop_app "$p" "$cls"
}

fixture() { echo "$root/tests/fixtures/gtk-headerbar.py"; }
states gtk3 '^org\.gnome\.Evince$' 1 python3 -I "$(fixture)" 3 0 org.gnome.Evince
states gtk4 '^org\.gnome\.Evince$' 1 python3 -I "$(fixture)" 4 0 org.gnome.Evince
if command -v evince >/dev/null; then
  states evince '^org\.gnome\.Evince$' 1 evince
fi
if command -v chromium >/dev/null; then
  # Chromium, a throwaway profile each, nothing from the owner's: "classic" is a fresh profile (what a new user gets with
  # Omarchy's seed: no theme set), "chromium" has its Preferences seeded with the GTK appearance (extensions.theme.system_theme 1).
  dead_proxy=127.0.0.1:9
  for mode in classic gtk; do
    prof=$work/chromium-$mode
    mkdir -p "$prof/Default"
    [[ $mode == gtk ]] && printf '{"extensions":{"theme":{"system_theme":1}}}\n' >"$prof/Default/Preferences"
    label=chromium-$mode
    # isolation-ok: states() starts it through client_run, which runs scripts/dev/isolated.sh
    states "$label" '^chromium$' $([[ $mode == gtk ]] && echo 1 || echo 0) chromium --user-data-dir="$prof" --no-first-run --no-default-browser-check \
      --password-store=basic --disable-background-networking --disable-component-update --disable-sync --proxy-server="$dead_proxy" \
      --ozone-platform=wayland --window-size=900,520 about:blank
    pkill -f -- "--user-data-dir=$prof" 2>/dev/null
    wait_gone '^chromium$'
  done
fi

say "captures (the pictures still need a look): $work/*.png"
python3 -I "$measure" check "$work" | tee -a "$log"
rc=${PIPESTATUS[0]}
((rc == 0 && fail == 0))
exit $?
