#!/usr/bin/env bash
# Window edge, shadow and the dark appearance's inner rim (ADR-0024 C-3 and C-4, notes of 2026-11-03): three windows on flat
# wallpapers, captured on GF-REF one at a time in the same frame: a Grassfield app that draws its own chrome (Settings), a
# third-party window under the plugin's titlebar (foot) and a third-party window that draws its own (Evince, GTK3 header
# bar; left out when it is not installed). The darkening along the middle of each side (tests/compositor/edge_measure.py) is
# compared with Hyprland's shadow model at the values of config/hypr/grassfield/looknfeel.lua, with the macOS 27 target and
# with the edge tokens the shell pushes; the light just inside the edge, on the sides and round the corner arcs, with the
# rim tokens. The edge and the shadow are Hyprland's and the shell's; the rim is the plugin's (CGrassfieldRim). Run it with
# and without the plugin (nested-up.sh --no-plugin, or `just plugin-unload`): the expectations follow `plugin list`.
#
# Usage: tests/compositor/window_edge.sh
# NESTED only: needs scripts/dev/nested-up.sh (GF-REF at any scale; the target is measured in points). Clients go through
# scripts/dev/isolated.sh with the nested socket only, hyprctl is read-only (scripts/nestctl -j) and the window moves go
# through scripts/nestctl. The dev settings file (appearance, wallpaper) is changed and restored at exit.
#
# Scenarios, per window: the light and the dark appearance, each over a flat light (#E6E6E6), mid-tone (#808080) and dark
# (#1E1E1E) wallpaper, the window active, then inactive (a foot window focused in a corner).
# Checks (device pixels along the middle of each side; 1 to 3 on Settings over the light wallpaper, as in batch 3):
#   1 the rendered shadow is the configured one: past the contact pixel, within 0.03 of Hyprland's model at every
#     distance on the left, right, top and bottom, active and inactive (the inactive colour's alpha)
#   2 the shadow against the macOS 27 target, active, past the contact pixel: within 0.06 on the sides, 0.03 on the top
#     and 0.08 on the bottom (one offset box holds a plateau under the window where macOS 27 slopes, ADR-0024 note
#     2026-11-03)
#   3 the contact edge, the border's one device pixel: its darkening over the shadow next to it (1 - (1 - contact) /
#     (1 - next)) within 0.03 of the tokens window.edge{Active,Inactive}Opacity{Light,Dark} (black), on every side
#   4 the inner rim on the straight sides, every window and wallpaper. The light appearance, and the dark one without the
#     plugin: none, the first device pixel inside within 2 levels of the next one in. The dark appearance with the plugin:
#     its white per point (the first pixel over the next one in, (L1 - L2) / (255 - L2), times its whole device pixels,
#     roundf(scale), over the scale) within 0.025 of window.rimDark{Active,Inactive}Opacity, and nothing further in (the
#     second and third pixels within 2 levels). A window whose edge is lighter than 200 there cannot show it: not judged.
#     Evince runs with GTK_THEME=Adwaita:dark (GTK3 does not follow the nested session's appearance) and its top side and
#     top corners are left out of 4 and 5: its header bar lights its own top row, with or without the plugin
#   5 the rim round the corner arcs (edge_measure.py corners: the brightest pixel of the rim's band against the window
#     further in, per 15-degree sector of each corner). With the plugin in the dark appearance: in every sector of every
#     corner at least 0.7 of the straight sides' step (Hyprland's inner glow left 34 there against 62 on the sides,
#     ADR-0024 note 2026-11-03). Otherwise no sector over 6 levels (a rim adds 21 to 27 there; over a light wallpaper
#     the contact pixel's anti-aliasing lightens a dark window's arc ends by up to 5)
#   6 the plugin's titlebar on foot: the rim along the bar's top (4, top side), none under the bar's hairline: the client's
#     first row within 2 levels of its second
# The edges and rims are also logged in levels (window, rim on the sides, rim on the arcs, contact pixel, shadow) for the
# record. Captures, 3x crops of the left edge and the bottom-left corner, 8x crops of the four corners, profiles, report and
# plot: .dev/window-edge/run-<time>/.
# Exit: 0 PASS, 1 FAIL, 2 usage or environment error.
#
# tests/compositor/window_edge.sh cost [ROUNDS]   (default 4; the plugin loaded)
#   What the rim costs a frame: the three windows open and overlapping in the dark appearance, the Settings window moved
#   back and forth (Hyprland's move animation: every frame redraws it and the windows under it), recorded by the plugin's
#   frame probe (`hyprctl grassfield-frames`: each render's CPU time, each presented frame). Each round measures the rim
#   on, then off: only the plugin's appearance changes (hl.plugin.grassfield.config("appearance", ...): light draws no
#   rim; the apps and the shell stay dark, so nothing else differs). The plugin is given the dark appearance back at the
#   end. Prints the render CPU time (mean, median, 95th percentile) and the presented intervals per mode; exit 0, or 2 on
#   an environment error (the numbers are information, not a verdict).
#
# tests/compositor/window_edge.sh c2   (the plugin loaded; gate C2 for the rim)
#   A foot window under the plugin's titlebar and the corner foot open in the dark appearance over #808080: the rim on the
#   four sides of foot's frame (bar included); the plugin unloaded through scripts/nestctl: Hyprland alive, both windows
#   still mapped, no rim and no titlebar (the first pixel inside within 2 levels of the next one in); loaded again: the
#   shell's appearance push seen, the titlebar and the rim back on the four sides; no plugin exception in Hyprland's log.
#   Captures: .dev/window-edge/run-<time>/c2-{before,unloaded,reloaded}.png. Exit 0 PASS, 1 FAIL, 2 environment error.
set -uo pipefail

mode=edges rounds=4
case ${1:-} in
  "") ;;
  cost) mode=cost; rounds=${2:-4} ;;
  c2) mode=c2 ;;
  *) echo "usage: tests/compositor/window_edge.sh [cost [ROUNDS] | c2]" >&2; exit 2 ;;
esac
[[ $rounds =~ ^[1-9][0-9]?$ ]] || { echo "window_edge: ROUNDS is 1 to 99" >&2; exit 2; }

root=$(git -C "$(dirname "$0")" rev-parse --show-toplevel)
dev=$root/.dev
out=${EDGE_OUTPUT:-GF-REF}
# shellcheck source=../../scripts/dev/pidfile.sh
. "$root/scripts/dev/pidfile.sh"
# shellcheck source=titlebar_geometry.sh
. "$root/tests/compositor/titlebar_geometry.sh" || exit 2
dev_nested_target "$dev" || exit 2
sock=$DEV_NESTED_SOCK sig=$DEV_NESTED_SIG

for tool in jq foot grim magick python3; do
  command -v "$tool" >/dev/null || { echo "window_edge: $tool not installed" >&2; exit 2; }
done
settings_bin=${EDGE_SETTINGS_BIN:-$dev/build/grassfield-settings} # isolation-ok: a path; open_window starts it through scripts/dev/isolated.sh
[[ -x $settings_bin ]] || { echo "window_edge: $settings_bin not built (apps/settings/build-direct.sh)" >&2; exit 2; }

stamp=$(date +%Y%m%d-%H%M%S)
run=$dev/window-edge/run-$stamp
mkdir -p "$run"
log=$run/run.log
say() { printf '%s %s\n' "$(date '+%H:%M:%S')" "$*" | tee -a "$log"; }
clients() { timeout 5 "$root/scripts/nestctl" -j clients; }
dispatch() { timeout 5 "$root/scripts/nestctl" dispatch "$1" >>"$log" 2>&1; }
pointer() { timeout 20 "$root/scripts/dev/pointer.sh" output "$out" "$@" >>"$log" 2>&1; }

mon_w=""
for _ in $(seq 1 40); do
  read -r mon_x mon_y mon_w mon_h scale < <(timeout 5 "$root/scripts/nestctl" -j monitors \
    | jq -r --arg o "$out" '.[] | select(.name == $o) | "\(.x) \(.y) \(.width) \(.height) \(.scale)"')
  [[ -n ${mon_w:-} ]] && break
  sleep 0.25
done
[[ -n ${mon_w:-} ]] || { echo "window_edge: output $out not found (waited 10 s)" >&2; exit 2; }
lw=$(awk -v w="$mon_w" -v s="$scale" 'BEGIN { printf "%d", w / s }')
lh=$(awk -v h="$mon_h" -v s="$scale" 'BEGIN { printf "%d", h / s }')

# The configured shadow (looknfeel.lua): range, render_power, offset y, the active and inactive colour's alpha; the corners.
lnf=$root/config/hypr/grassfield/looknfeel.lua
shadow_block=$(sed -n '/^    shadow = {/,/^    },/p' "$lnf")
cfg() { sed -n "s/^ *$1 = \\([0-9.]*\\),.*/\\1/p" <<<"$shadow_block" | head -n 1; }
s_range=$(cfg range) s_power=$(cfg render_power)
s_off=$(sed -n 's/^ *offset = { *[-0-9.]*, *\([-0-9.]*\) *},.*/\1/p' <<<"$shadow_block")
hex_alpha() { awk -v h="$((16#$1))" 'BEGIN { printf "%.4f", h / 255 }'; }
s_alpha=$(hex_alpha "$(sed -n 's/^ *color = "rgba(......\(..\))",.*/\1/p' <<<"$shadow_block")")
s_alpha_in=$(hex_alpha "$(sed -n 's/^ *color_inactive = "rgba(......\(..\))",.*/\1/p' <<<"$shadow_block")")
[[ -n $s_range && -n $s_power && -n $s_off ]] || { echo "window_edge: shadow values not found in $lnf" >&2; exit 2; }
rounding=$(sed -n 's/^    rounding = \([0-9.]*\),.*/\1/p' "$lnf" | head -n 1)
rounding_power=$(sed -n 's/^    rounding_power = \([0-9.]*\),.*/\1/p' "$lnf" | head -n 1)
[[ -n $rounding && -n $rounding_power ]] || { echo "window_edge: rounding not found in $lnf" >&2; exit 2; }

# The plugin draws the rim and foot's titlebar; without it neither is expected.
plugin=0
timeout 5 "$root/scripts/nestctl" -j plugin list 2>/dev/null \
  | jq -e '[.[]? | select(.name == "grassfield-compositor")] | length > 0' >/dev/null 2>&1 && plugin=1
say "window_edge: $out ${mon_w}x${mon_h} scale $scale (${lw}x${lh} pt); shadow range $s_range power $s_power alpha $s_alpha (inactive $s_alpha_in) offset $s_off; rounding $rounding power $rounding_power; plugin $( ((plugin)) && echo loaded || echo 'NOT loaded: no rim, no titlebar expected')"

pids=()
settings_file=$dev/config/grassfield.json
settings_backup=$run/settings.backup
had_settings=0
[[ -f $settings_file ]] && { cp "$settings_file" "$settings_backup"; had_settings=1; }
cleanup() {
  local p
  for p in "${pids[@]}"; do dev_may_signal "$p" && kill "$p" 2>/dev/null; done
  if ((had_settings)); then cp "$settings_backup" "$settings_file"; else rm -f "$settings_file"; fi
}
trap cleanup EXIT

fail=0
check() { # <label> <0 = ok> <details>
  if [[ $2 == 0 ]]; then say "  $1: OK   ($3)"; else say "  $1: FAIL ($3)"; fail=1; fi
}

look_now="" # the appearance the shell was last seen pushing
set_look() { # <dark|light> <#rrggbb wallpaper>: rewrite the dev settings file, wait for the shell's edge push and the crossfade
  local base=$root/config/defaults/grassfield.json n
  ((had_settings)) && base=$settings_backup
  mkdir -p "$dev/config"
  n=$(grep -c "push window edge ($1)" "$dev/shell.log" 2>/dev/null)
  jq --arg a "$1" --arg c "$2" '.appearance = $a | .wallpaper.source = "color" | .wallpaper.color = $c' "$base" \
    >"$settings_file.tmp" && mv "$settings_file.tmp" "$settings_file"
  if [[ $1 != "$look_now" ]]; then # a shell that has just started can take seconds to read the file (load)
    for _ in $(seq 1 150); do
      (($(grep -c "push window edge ($1)" "$dev/shell.log" 2>/dev/null) > ${n:-0})) && { look_now=$1; break; }
      sleep 0.1
    done
    [[ $look_now == "$1" ]] || say "  no 'push window edge ($1)' in the shell log after 15 s"
  fi
  sleep 1.5 # the app's own appearance change, the debounced push (the plugin's appearance with it), a frame
}

# New windows open on the output under the pointer.
pointer abs 8 $((lh / 2)) sleep 200

bus=""
[[ -f $dev/bus.address ]] && bus=$(<"$dev/bus.address")

# A foot window in the top-left corner, clear of the measured lines and of their shadow: focusing it makes the measured
# window inactive.
WAYLAND_DISPLAY=$sock setsid "$root/scripts/dev/isolated.sh" --name window-edge foot --title gf-edge-other -w 300x160 \
  -o colors-dark.alpha=1 -o colors-light.alpha=1 sh -c 'printf "\033[?25l"; exec sleep 900' >/dev/null 2>&1 </dev/null &
pids+=("$!")
faddr=""
for _ in $(seq 1 40); do
  faddr=$(clients | jq -r '.[] | select(.title == "gf-edge-other") | .address' | head -n 1)
  [[ -n $faddr ]] && break
  sleep 0.25
done
[[ -n $faddr ]] || { say "window_edge: setup error: no foot window"; exit 2; }
dispatch "hl.dsp.window.move({ x = $((mon_x + 40)), y = $((mon_y + 60)), window = 'address:$faddr' })"

# The measured frame, 640 x 400 pt, in the middle of the space between the menu bar and the Dock: the surface, and above it
# the plugin's titlebar on foot (the frame keeps its place and size).
ww=640 wh=400
wx=$(((lw - ww) / 2)) wy=$((24 + (lh - 24 - 70 - wh) / 2))

win_pid="" addr="" bar=0 own="" gx=0 gy=0 gw=0 gh=0 fy=0 fh=0
open_window() { # <settings|foot|evince> [x y]: start it and place its frame there (pt; the measured place by default); false
  # when it never mapped
  local match at_x=${2:-$wx} at_y=${3:-$wy}
  bar=0 own=""
  case $1 in
    settings)
      "$root/scripts/dev/isolated.sh" --name window-edge --config-home "$dev/config" --state-home "$dev/state" -- \
        env WAYLAND_DISPLAY="$sock" DBUS_SESSION_BUS_ADDRESS="$bus" QT_QPA_PLATFORM=wayland QT_NO_XDG_DESKTOP_PORTAL=1 \
        QML_IMPORT_PATH="$root/ui:$dev/build/qml" GRASSFIELD_TRANSLATIONS_DIR="$dev/translations" GRASSFIELD_LANG=en \
        HYPRLAND_INSTANCE_SIGNATURE="$sig" "$settings_bin" >>"$log" 2>&1 </dev/null &
      match='.class == "org.grassfield.Settings"' ;;
    foot)
      WAYLAND_DISPLAY=$sock setsid "$root/scripts/dev/isolated.sh" --name window-edge foot --title gf-edge-foot \
        -o colors-dark.alpha=1 -o colors-light.alpha=1 sh -c 'printf "\033[?25l"; exec sleep 900' >/dev/null 2>&1 </dev/null &
      match='.title == "gf-edge-foot"'
      ((plugin)) && bar=$GF_TB_HEIGHT ;;
    evince)
      # Dark whatever the appearance: GTK3 does not follow the nested session's (a light Evince shows a rim of 4 levels).
      WAYLAND_DISPLAY=$sock DBUS_SESSION_BUS_ADDRESS=$bus GDK_BACKEND=wayland GTK_THEME=Adwaita:dark \
        setsid "$root/scripts/dev/isolated.sh" --name window-edge-evince -- evince >>"$log" 2>&1 </dev/null &
      match='.class == "org.gnome.Evince"'
      own=top,top-left,top-right ;; # its header bar draws its own light top row, in both appearances
  esac
  win_pid=$!
  pids+=("$win_pid")
  addr=""
  for _ in $(seq 1 120); do # up to 30 s: GTK on the private bus can wait for an accessibility bus
    addr=$(clients | jq -r ".[] | select($match) | .address" | head -n 1)
    [[ -n $addr ]] && break
    sleep 0.25
  done
  [[ -n $addr ]] || return 1
  sleep 1
  dispatch "hl.dsp.window.resize({ x = $ww, y = $((wh - bar)), exact = true, window = 'address:$addr' })"
  dispatch "hl.dsp.window.move({ x = $((mon_x + at_x)), y = $((mon_y + at_y + bar)), window = 'address:$addr' })"
  sleep 0.8
  read -r gx gy gw gh < <(clients | jq -r --arg a "$addr" --argjson mx "$mon_x" --argjson my "$mon_y" \
    '.[] | select(.address == $a) | "\(.at[0] - $mx) \(.at[1] - $my) \(.size[0]) \(.size[1])"')
  fy=$((gy - bar)) fh=$((gh + bar))
  say "$1: surface ${gw}x${gh} at ($gx,$gy) pt, frame ${gw}x${fh} at ($gx,$fy) (titlebar $bar)"
}
close_window() {
  dev_may_signal "$win_pid" && kill "$win_pid" 2>/dev/null
  for _ in $(seq 1 40); do
    [[ -z $(clients | jq -r --arg a "$addr" '.[] | select(.address == $a) | .address') ]] && break
    sleep 0.25
  done
}

px() { awk -v v="$1" -v s="$scale" 'BEGIN { v = v * s; printf "%d", (v >= 0 ? int(v + 0.5) : -int(-v + 0.5)) }'; } # C round
rim_px=$(awk -v s="$scale" 'BEGIN { printf "%d", s + 0.5 }') # roundf(1 pt x scale): the rim's whole device pixels
inside() { # <profile json> <side> <k>: the level of the k-th device pixel inside the edge (1 the first), mean of the channels
  jq -r --arg s "$2" --argjson k "$3" '.sides[$s].rgb[8 - $k] | add / 3' "$1"
}
capture() { # <name> <wallpaper hex>: once the wallpaper 150 px left of the window is that colour (the crossfade done; 10 s)
  local try bx by fx0 fy0 fx1 fy1 r c
  bx=$(($(px "$gx") - 150)) by=$(px "$((fy + fh / 2))")
  for try in $(seq 1 20); do
    WAYLAND_DISPLAY=$sock grim -t ppm -o "$out" "$run/$1.ppm" 2>>"$log"
    python3 -I "$root/tests/compositor/edge_measure.py" background "$run/$1.ppm" "$bx" "$by" "$2" 2>>"$log" && break
    ((try == 20)) && say "  $1: the wallpaper is not $2 after 10 s (measured anyway)"
    sleep 0.5
  done
  magick "$run/$1.ppm" "$run/$1.png"
  python3 -I "$root/tests/compositor/edge_measure.py" profile "$run/$1.ppm" "$scale" "$gx" "$fy" "$gw" "$fh" "$2" >"$run/$1.json"
  python3 -I "$root/tests/compositor/edge_measure.py" corners "$run/$1.ppm" "$scale" "$gx" "$fy" "$gw" "$fh" "$rounding" \
    "$rounding_power" >"$run/$1-corners.json"
  ((bar > 0)) && python3 -I "$root/tests/compositor/edge_measure.py" column "$run/$1.ppm" "$(px "$((gx + gw / 2))")" \
    "$(($(px "$gy") - 3))" 7 >"$run/$1-bar.json"
  fx0=$(px "$gx") fy0=$(px "$fy") fx1=$(px "$((gx + gw))") fy1=$(px "$((fy + fh))")
  magick "$run/$1.ppm" -crop "60x40+$((fx0 - 40))+$(((fy0 + fy1) / 2 - 20))" +repage -filter point -resize 300% "$run/$1-left-3x.png"
  magick "$run/$1.ppm" -crop "160x140+$((fx0 - 60))+$((fy1 - 40))" +repage -filter point -resize 300% "$run/$1-corner-3x.png"
  # The four corners at 8x: the corner square as Hyprland draws it (CWindow::rounding() = rounding x power / 2, times the
  # scale, cut to whole device pixels) and 8 device pixels past the edge.
  r=$(awk -v r="$rounding" -v p="$rounding_power" -v s="$scale" 'BEGIN { printf "%d", int(r * p / 2 * s) + 8 }')
  for c in "tl $((fx0 - 8)) $((fy0 - 8))" "tr $((fx1 - r + 8)) $((fy0 - 8))" "bl $((fx0 - 8)) $((fy1 - r + 8))" \
    "br $((fx1 - r + 8)) $((fy1 - r + 8))"; do
    read -r cn cx cy <<<"$c"
    magick "$run/$1.ppm" -crop "${r}x${r}+$cx+$cy" +repage -filter point -resize 800% "$run/$1-$cn-8x.png"
  done
}

if [[ $mode == cost ]]; then
  ((plugin)) || { say "window_edge cost: the plugin is not loaded"; exit 2; }
  ctl() { timeout 5 "$root/scripts/nestctl" "$@"; }
  set_look dark "#808080"
  open_window foot $((wx - 300)) $((wy + 60)) || { say "window_edge cost: setup error: foot did not map"; exit 2; }
  if command -v evince >/dev/null; then
    open_window evince $((wx + 300)) $((wy + 30)) || { say "window_edge cost: setup error: evince did not map"; exit 2; }
  fi
  open_window settings || { say "window_edge cost: setup error: settings did not map"; exit 2; }
  s_addr=$addr
  for i in $(seq 1 "$rounds"); do
    for rim in on off; do
      look=dark
      [[ $rim == off ]] && look=light
      ctl dispatch "hl.plugin.grassfield.config(\"appearance\", \"$look\")" >>"$log" 2>&1
      dispatch "hl.dsp.focus({ window = 'address:$s_addr' })"
      sleep 0.5
      ctl grassfield-frames-start >>"$log" 2>&1
      # The probe keeps its rings across recordings: this segment is what comes after the last render recorded now.
      ctl grassfield-frames 2>>"$log" | jq -r --arg o "$out" '[.monitors[] | select(.name == $o) | .renders[][0]] | max // 0' \
        >"$run/frames-$rim-$i.from"
      for k in $(seq 1 30); do
        dispatch "hl.dsp.window.move({ x = $((mon_x + wx + (k % 2) * 60)), y = $((mon_y + wy)), window = 'address:$s_addr' })"
        sleep 0.1
      done
      ctl grassfield-frames >"$run/frames-$rim-$i.json" 2>>"$log"
      say "round $i, rim $rim: $(jq -r --arg o "$out" --argjson f "$(<"$run/frames-$rim-$i.from")" '.monitors[] | select(.name == $o)
        | "\([.renders[] | select(.[0] > $f)] | length) renders, \([.presented[] | select(. > $f)] | length) frames presented"' "$run/frames-$rim-$i.json" 2>/dev/null)"
    done
  done
  ctl dispatch 'hl.plugin.grassfield.config("appearance", "dark")' >>"$log" 2>&1
  summary() { # <label>: n, mean, median, 95th percentile of the sorted numbers on stdin (microseconds)
    awk -v l="$1" '{ v[NR] = $1; s += $1 } END { if (NR == 0) { print l ": none"; exit }
      p = int(0.95 * NR + 0.5); if (p < 1) p = 1
      printf "%s: n %d, mean %.0f us, median %.0f us, p95 %.0f us\n", l, NR, s / NR, v[int((NR + 1) / 2)], v[p] }'
  }
  for rim in on off; do
    say "rim $rim: $(for f in "$run"/frames-"$rim"-*.json; do
      jq -r --arg o "$out" --argjson f "$(<"${f%.json}.from")" '.monitors[] | select(.name == $o) | .renders[] | select(.[0] > $f) | .[1]' "$f"
    done | sort -n | summary "render CPU")"
    say "rim $rim: $(for f in "$run"/frames-"$rim"-*.json; do
      jq -r --arg o "$out" --argjson f "$(<"${f%.json}.from")" '.monitors[] | select(.name == $o) | [.presented[] | select(. > $f)]
        | . as $p | range(1; length) | $p[.] - $p[. - 1]' "$f"
    done | sort -n | summary "presented interval")"
  done
  say "frames: $run"
  exit 0
fi

if [[ $mode == c2 ]]; then
  ((plugin)) || { say "window_edge c2: the plugin is not loaded"; exit 2; }
  so=${GRASSFIELD_PLUGIN:-$root/compositor/build/grassfield-compositor.so}
  ctl() { timeout 10 "$root/scripts/nestctl" "$@"; }
  regeom() { # <titlebar height>: the window's boxes again (the titlebar comes and goes with the plugin)
    bar=$1
    read -r gx gy gw gh < <(clients | jq -r --arg a "$addr" --argjson mx "$mon_x" --argjson my "$mon_y" \
      '.[] | select(.address == $a) | "\(.at[0] - $mx) \(.at[1] - $my) \(.size[0]) \(.size[1])"')
    fy=$((gy - bar)) fh=$((gh + bar))
  }
  steps() { # <json>: the first pixel over the next one in, per side (levels)
    local side
    for side in left right top bottom; do
      awk -v a="$(inside "$1" "$side" "$rim_px")" -v b="$(inside "$1" "$side" $((rim_px + 1)))" -v s="$side" \
        'BEGIN { printf "%s %.1f\n", s, a - b }'
    done
  }
  expect_rim() { # <name> <yes|no>
    local out_ok=0 list
    list=$(steps "$run/$1.json")
    if [[ $2 == yes ]]; then
      awk '$2 < 8 { bad = 1 } END { exit bad }' <<<"$list" || out_ok=1
    else
      awk '$2 > 2 || $2 < -2 { bad = 1 } END { exit bad }' <<<"$list" || out_ok=1
    fi
    check "c2 $1: rim $2" "$out_ok" "$(tr '\n' ' ' <<<"$list")(levels over the window; a rim is about 27 at 1.25)"
  }
  set_look dark "#808080"
  open_window foot || { say "window_edge c2: setup error: foot did not map"; exit 2; }
  dispatch "hl.dsp.focus({ window = 'address:$addr' })"
  sleep 0.6
  capture c2-before "#808080"
  expect_rim c2-before yes
  hyprlog=${XDG_RUNTIME_DIR:-/run/user/$(id -u)}/hypr/$sig/hyprland.log
  [[ -r $hyprlog ]] || { say "window_edge c2: Hyprland's log $hyprlog is not readable"; exit 2; }
  exceptions_before=$(grep -c '\[grassfield\].*exception' "$hyprlog")
  ctl plugin unload "$so" >>"$log" 2>&1
  sleep 1.5
  ctl version >/dev/null 2>&1
  check "c2 unload: Hyprland alive" $? "nestctl version after the unload"
  ctl -j plugin list 2>/dev/null | jq -e '[.[]? | select(.name == "grassfield-compositor")] | length == 0' >/dev/null 2>&1
  check "c2 unload: the plugin is gone" $? "plugin list"
  n=$(clients | jq --arg a "$addr" --arg b "$faddr" '[.[] | select(.address == $a or .address == $b)] | length')
  [[ $n == 2 ]]
  check "c2 unload: both windows still mapped" $? "$n of 2"
  regeom 0
  capture c2-unloaded "#808080"
  expect_rim c2-unloaded no
  pushes=$(grep -c "compositor setting appearance = dark" "$dev/shell.log" 2>/dev/null)
  ctl plugin load "$so" >>"$log" 2>&1
  for _ in $(seq 1 100); do
    (($(grep -c "compositor setting appearance = dark" "$dev/shell.log" 2>/dev/null) > ${pushes:-0})) && break
    sleep 0.1
  done
  (($(grep -c "compositor setting appearance = dark" "$dev/shell.log" 2>/dev/null) > ${pushes:-0}))
  check "c2 reload: the shell pushed the appearance again" $? "shell log"
  sleep 1.5
  regeom "$GF_TB_HEIGHT"
  capture c2-reloaded "#808080"
  expect_rim c2-reloaded yes
  exceptions_after=$(grep -c '\[grassfield\].*exception' "$hyprlog")
  ((exceptions_after == exceptions_before))
  check "c2: no plugin exception in Hyprland's log" $? "$exceptions_before before, $exceptions_after after ($hyprlog)"
  say "captures: $run"
  if ((fail)); then say "window_edge c2: FAIL"; exit 1; fi
  say "window_edge c2: PASS"
  exit 0
fi

walls=(E6E6E6 808080 1E1E1E)
measured=()
for win in settings foot evince; do
  if [[ $win == evince ]] && ! command -v evince >/dev/null; then
    say "evince: not installed, the third-party window that draws its own titlebar is not measured"
    continue
  fi
  open_window "$win" || { say "window_edge: setup error: $win did not map"; exit 2; }
  pointer abs 8 $((lh / 2)) sleep 200
  for look in light dark; do
    for wall in "${walls[@]}"; do
      set_look "$look" "#$wall"
      dispatch "hl.dsp.focus({ window = 'address:$addr' })"
      sleep 0.6
      capture "$win-$look-$wall-active" "#$wall"
      dispatch "hl.dsp.focus({ window = 'address:$faddr' })"
      sleep 0.6
      capture "$win-$look-$wall-inactive" "#$wall"
      say "captured $win, $look over #$wall, active and inactive"
    done
  done
  printf '%s %s %s\n' "$win" "$bar" "${own:--}" >>"$run/windows.txt"
  measured+=("$win")
  close_window
done

python3 -I "$root/tests/compositor/edge_measure.py" report "$run/report-active.txt" "$run/profile-active.svg" \
  "$s_range" "$s_power" "$s_alpha" "$s_off" "$run"/settings-{light,dark}-{E6E6E6,808080}-active.json 2>>"$log"
python3 -I "$root/tests/compositor/edge_measure.py" report "$run/report-inactive.txt" "$run/profile-inactive.svg" \
  "$s_range" "$s_power" "$s_alpha_in" "$s_off" "$run"/settings-{light,dark}-{E6E6E6,808080}-inactive.json 2>>"$log"
for f in profile-active profile-inactive; do rsvg-convert "$run/$f.svg" -o "$run/$f.png" 2>>"$log"; done
declare -A r=()
while IFS='=' read -r k v; do r[${k#settings-}]=${v%% *}; done < <(cat "$run/report-active.txt" "$run/report-inactive.txt")

# 1 the rendered shadow is the configured one
for state in active inactive; do
  for side in left right top bottom; do
    v=${r[light-E6E6E6-$state.$side.model_max_dev]:-9}
    awk -v v="$v" 'BEGIN { exit !(v <= 0.03) }'
    check "1 settings, light wallpaper, $state, $side: render = model" $? "largest difference $v (at most 0.03)"
  done
done

# 2 against the macOS 27 target
for side in left right top bottom; do
  case $side in top) lim=0.03 ;; bottom) lim=0.08 ;; *) lim=0.06 ;; esac
  v=${r[light-E6E6E6-active.$side.mac27_max_dev]:-9}
  awk -v v="$v" -v l="$lim" 'BEGIN { exit !(v <= l) }'
  check "2 settings, light wallpaper, active, $side: shadow against macOS 27" $? "largest difference $v (at most $lim; first 16 pt ${r[light-E6E6E6-active.$side.mac27_max_dev_16pt]:-?})"
done

# 3 the contact edge
token() { jq -r --arg g "${2:-window}" --arg k "$1" '.[$g][$k].value' "$root/ui/tokens/tokens.json"; }
contact_over() { # <json> <side>: the contact pixel's darkening over the shadow next to it
  jq -r --arg s "$2" '.sides[$s].alpha | "\(.[0]) \(.[1])"' "$1" | awk '{ printf "%.3f", 1 - (1 - $1) / (1 - $2) }'
}
for look in light dark; do
  L=${look^}
  for state in active inactive; do
    want=$(token "edge${state^}Opacity$L")
    for side in left right top bottom; do
      v=$(contact_over "$run/settings-$look-E6E6E6-$state.json" "$side")
      awk -v v="$v" -v w="$want" 'BEGIN { d = v - w; if (d < 0) d = -d; exit !(d <= 0.03) }'
      check "3 settings, $look, $state, $side: contact edge" $? "darkening over the shadow $v (token $want +-0.03)"
    done
  done
done

# 4 the rim on the straight sides
rim_per_pt() { # <L1> <L2>: the first pixel's white over the next one in, per point
  awk -v a="$1" -v b="$2" -v n="$rim_px" -v s="$scale" 'BEGIN { printf "%.3f", (a - b) / (255 - b) * n / s }'
}
owned() { # <window> <side or corner>: the app draws that edge itself (windows.txt: Evince's header bar, its top)
  [[ ,$(awk -v w="$1" '$1 == w { print $3 }' "$run/windows.txt"), == *,"$2",* ]]
}
for win in "${measured[@]}"; do
  for side in top top-left top-right; do
    owned "$win" "$side" && say "  4-5 $win: its $side left out (the app's own header bar lights its top row in both appearances)"
  done
done
for win in "${measured[@]}"; do
  for look in light dark; do
    for wall in "${walls[@]}"; do
      for state in active inactive; do
        j=$run/$win-$look-$wall-$state.json
        for side in left right top bottom; do
          owned "$win" "$side" && continue
          l1=$(inside "$j" "$side" "$rim_px") l2=$(inside "$j" "$side" $((rim_px + 1))) l3=$(inside "$j" "$side" $((rim_px + 2)))
          if [[ $look == dark ]] && ((plugin)); then
            if awk -v b="$l2" 'BEGIN { exit !(b > 200) }'; then
              say "  4 $win, dark over #$wall, $state, $side: not judged (the window's edge is $l2, too light to show a rim)"
              continue
            fi
            want=$(token "rimDark${state^}Opacity")
            v=$(rim_per_pt "$l1" "$l2")
            awk -v v="$v" -v w="$want" -v b="$l2" -v c="$l3" 'BEGIN { d = v - w; if (d < 0) d = -d; e = b - c; if (e < 0) e = -e; exit !(d <= 0.025 && e <= 2) }'
            check "4 $win, dark over #$wall, $state, $side: rim" $? "white $v per pt over the window (token $want +-0.025): levels $l3, $l2, then $l1 at the edge"
          else
            awk -v a="$l1" -v b="$l2" 'BEGIN { d = a - b; if (d < 0) d = -d; exit !(d <= 2) }'
            check "4 $win, $look over #$wall, $state, $side: no rim" $? "first pixel $l1 against $l2 (at most 2 levels apart)"
          fi
        done
      done
    done
  done
done

# 5 the rim round the corner arcs
for win in "${measured[@]}"; do
  for look in light dark; do
    for wall in "${walls[@]}"; do
      for state in active inactive; do
        j=$run/$win-$look-$wall-$state.json
        straight=$(for side in left right top bottom; do
          owned "$win" "$side" && continue
          printf '%s %s\n' "$(inside "$j" "$side" "$rim_px")" "$(inside "$j" "$side" $((rim_px + 1)))"
        done | awk '{ s += $1 - $2 } END { printf "%.1f", s / NR }')
        arcs=$(jq -r '.corners | to_entries[] | .key as $c | .value[] | select(.rim != null and .base != null)
          | "\($c) \(.deg[0]) \(.rim) \(.base)"' "$run/$win-$look-$wall-$state-corners.json" \
          | while read -r c rest; do owned "$win" "$c" || printf '%s %s\n' "$c" "$rest"; done)
        worst=$(awk '{ d = $3 - $4; if (NR == 1 || d < m) { m = d; at = $1 " " $2 } } END { printf "%.1f %s", m, at }' <<<"$arcs")
        most=$(awk '{ d = $3 - $4; if (NR == 1 || d > m) m = d } END { printf "%.1f", m }' <<<"$arcs")
        if [[ $look == dark ]] && ((plugin)) && awk -v s="$straight" 'BEGIN { exit !(s >= 4) }'; then
          awk -v w="${worst%% *}" -v s="$straight" 'BEGIN { exit !(w >= 0.7 * s) }'
          check "5 $win, dark over #$wall, $state: rim round the arcs" $? "weakest sector ${worst%% *} levels over the window (${worst#* } deg), strongest $most, straight sides $straight (at least 0.7 of them)"
        elif [[ $look == dark ]] && ((plugin)); then
          say "  5 $win, dark over #$wall, $state: not judged (no measurable rim on the straight sides: $straight levels)"
        else
          awk -v m="$most" 'BEGIN { exit !(m <= 6) }'
          check "5 $win, $look over #$wall, $state: no rim on the arcs" $? "strongest sector $most levels over the window (at most 6: a rim adds 21 to 27 here, the contact pixel's anti-aliasing up to 5 at the arc's ends over a light wallpaper)"
        fi
      done
    done
  done
done

# 6 the titlebar's hairline: no light row under it
for win in "${measured[@]}"; do
  [[ $(awk -v w="$win" '$1 == w { print $2 }' "$run/windows.txt") -gt 0 ]] || continue
  for look in light dark; do
    for state in active inactive; do
      col=$(jq -r 'map(tostring) | join(" ")' "$run/$win-$look-E6E6E6-$state-bar.json")
      read -r _ _ hairline top second _ <<<"$col"
      awk -v a="$top" -v b="$second" 'BEGIN { d = a - b; exit !(d <= 2) }'
      check "6 $win, $look, $state: nothing under the titlebar's hairline" $? "rows bar, bar, hairline $hairline, client $top, $second ($col)"
    done
  done
done

# For the record: the dark edge and rim in levels (macOS 27, Notes: window 41, rim 62, outer pixel 11, shadow 153).
levels() { # <json> <side>: window, rim, contact pixel and the next one outside, in levels (mean of the channels)
  jq -r --arg s "$2" --argjson n "$rim_px" '.sides[$s].rgb | [.[7 - $n], .[8 - $n], .[8], .[9]] | map(add / 3 | floor)
    | "window \(.[0]), rim \(.[1]), contact \(.[2]), shadow \(.[3])"' "$1"
}
arc_levels() { # <corners json>: the rim's brightest and weakest sector of every corner, in levels
  jq -r '[.corners[][] | select(.rim != null)] | "arcs: rim \(map(.rim) | min | floor)-\(map(.rim) | max | floor) over window \(map(.base) | min | floor)-\(map(.base) | max | floor)"' "$1"
}
for win in "${measured[@]}"; do
  for wall in "${walls[@]}"; do
    for state in active inactive; do
      j=$run/$win-dark-$wall-$state
      say "  $win, dark over #$wall, $state: left $(levels "$j.json" left); top $(levels "$j.json" top); $(arc_levels "$j-corners.json")"
    done
  done
done

say "captures, crops, profiles and plots: $run"
if ((fail)); then say "window_edge: FAIL"; exit 1; fi
say "window_edge: PASS"
exit 0
