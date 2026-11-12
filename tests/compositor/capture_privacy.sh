#!/usr/bin/env bash
# SEC-01 / compositor FR59, nested: the plugin's own drawings of a window hidden from captures (Hyprland's no_screen_share;
# privacy.lua gives it to the app id Bitwarden) show none of its pixels, and not its title, in a capture of a display.
# tests/security/lock_privacy.sh covers the window at its place (Hyprland's box and the titlebar join); this covers what
# the plugin draws elsewhere, each while a capture (grim, wlr-screencopy) is in progress:
#   setup     on OUTPUT (GF-REF) two foot windows side by side, 560x360, no text: "gf-capture-twin" filled green
#             (unprotected: the control) and "Bitwarden" filled cyan (protected; Hyprland's getprop no_screen_share must
#             say true). Self-check: an unprotected cyan foot is captured cyan (the detector sees cyan), then closed;
#             the twin is captured green
#   still     a capture: no cyan px anywhere (Hyprland's box and the join), the twin's bar shows its title (text: the
#             bar's middle is not flat) and Bitwarden's bar shows none (flat)
#   overview  the shell's Overview (`qs ipc call overview open`; the plugin's overview "open" event required): no cyan
#             px, the twin's miniature captured green (its plate is black while captured)
#   stages    Stages on with the strip stand-in tests/compositor/stages-fixture (as soak.sh stages), both windows moved
#             into strip stages: no cyan px, the twin's tile captured green; Stages off
#   minimize  Bitwarden minimized with its button, Shift held (slow motion), captures at 5 points of its animation: no
#             cyan px in any; then the twin the same way: some capture shows its animation (green px), the control
#   health    the nested Hyprland alive, no grassfield exception in its log since the start
# The plugin draws the protected window's pixels on screen between captures; only the captured frames are checked.
# NESTED only (scripts/dev/nested-up.sh with grassfield-compositor loaded and the shell running). Exit: 0 PASS, 1 FAIL,
# 2 harness or environment error (a precondition this run could not set up: no verdict on the product).
set -uo pipefail

root=$(git -C "$(dirname "$0")" rev-parse --show-toplevel)
dev=$root/.dev
# shellcheck source=../../scripts/dev/pidfile.sh
. "$root/scripts/dev/pidfile.sh"
dev_nested_target "$dev" || exit 2
sig=$DEV_NESTED_SIG sock=$DEV_NESTED_SOCK hypr_pid=$DEV_NESTED_PID
main=$(cat "$dev/main.instance" 2>/dev/null || true)
[[ -n $sig && -n $sock && $sig != "$main" && $sig != "${HYPRLAND_INSTANCE_SIGNATURE:-}" && $sock != "${WAYLAND_DISPLAY:-}" ]] \
  || { echo "capture_privacy: refusing: no nested instance, or the recorded one is the main session" >&2; exit 2; }
for tool in grim magick foot jq awk timeout socat; do
  command -v "$tool" >/dev/null || { echo "capture_privacy: $tool is not installed" >&2; exit 2; }
done
# shellcheck source=titlebar_geometry.sh
. "$root/tests/compositor/titlebar_geometry.sh" || exit 2

out=${CP_OUTPUT:-GF-REF}
run=$dev/capture-privacy/run-$(date +%Y%m%d-%H%M%S)
mkdir -p "$run"
log=$run/run.log
win_w=560 win_h=360 inset=16
cyan="#00ffff" green="#00ff00"
status=0 harness=0 why=""
started=$(date '+%Y-%m-%d %H:%M:%S')
hyprlog=${XDG_RUNTIME_DIR:-/run/user/$(id -u)}/hypr/$sig/hyprland.log
log_lines_before=$(wc -l <"$hyprlog" 2>/dev/null || echo 0)

say() { printf '%s %s\n' "$(date '+%H:%M:%S.%3N')" "$*" | tee -a "$log"; }
pass() { say "  PASS $*"; }
fail() { say "  FAIL $*"; status=1; }
harness() { say "  HARNESS $*"; harness=1; }
nested() { env WAYLAND_DISPLAY="$sock" HYPRLAND_INSTANCE_SIGNATURE="$sig" "$@"; }
hypr() { nested timeout -k 2 5 hyprctl "$@" 2>/dev/null; }
nestctl() { timeout 10 "$root/scripts/nestctl" "$@"; }
ipc() { nested timeout -k 2 5 qs ipc -p "$root/shell" call "$@" 2>/dev/null; }
pointer() { timeout -k 2 20 "$root/scripts/dev/pointer.sh" output "$out" "$@" >>"$log" 2>&1; }
hold_shift() { "$root/scripts/dev/keys.sh" -M shift -s "$1" -m shift >>"$log" 2>&1 & } # <ms>, in the background

# The plugin's events (socket2), for the overview's state and the minimize moves.
events=$run/events.log
socat -u UNIX-CONNECT:"${XDG_RUNTIME_DIR:-/run/user/$(id -u)}/hypr/$sig/.socket2.sock" STDOUT </dev/null >"$events" 2>>"$log" &
events_pid=$!
fixture_pid=""
pids=()
cleanup() {
  ipc overview close >/dev/null
  nestctl dispatch 'hl.plugin.grassfield.stages([[{"op":"off","durationMs":0}]])' >/dev/null 2>&1
  nestctl dispatch 'hl.plugin.grassfield.config("stagesEnabled", "false")' >/dev/null 2>&1
  [[ -n $fixture_pid ]] && kill "$fixture_pid" 2>/dev/null
  local p
  for p in "${pids[@]}"; do kill "$p" 2>/dev/null; done
  kill "$events_pid" 2>/dev/null
}
trap cleanup EXIT

hypr -j grassfield | jq -e '.features | index("overview") and index("minimize") and index("stages-available")' >/dev/null 2>&1 \
  || { echo "capture_privacy: the loaded plugin does not advertise overview, minimize and stages-available" >&2; exit 2; }

mon_x="" mon_y="" mon_w="" mon_h="" mon_scale=""
read -r mon_x mon_y mon_w mon_h mon_scale < <(hypr -j monitors | jq -r --arg o "$out" \
  '.[] | select(.name == $o) | "\(.x) \(.y) \(.width / .scale | floor) \(.height / .scale | floor) \(.scale)"')
[[ ${mon_w:-} =~ ^[0-9]+$ && ${mon_h:-} =~ ^[0-9]+$ ]] || { echo "capture_privacy: Hyprland lists no monitor $out" >&2; exit 2; }

# ---- captures and measures (as tests/security/lock_privacy.sh) ----

# One capture of $out to <png>; never an older file in its place. Bounded: a display that draws no frame fails.
grab() { # <png>
  local start t
  start=$(date +%s)
  rm -f "$1"
  nested timeout -k 2 10 grim -o "$out" "$1" 2>>"$log" || return 1
  t=$(stat -c %Y "$1" 2>/dev/null) && [[ -s $1 ]] && ((t >= start))
}
count_colour() { # <png> <#rrggbb>: pixels within 8 % of the colour
  magick "$1" -alpha off -fuzz 8% -fill black +opaque "$2" -fill white -opaque "$2" -format '%[fx:round(mean*w*h)]' info: 2>/dev/null || echo error
}
client_info() { # <address> -> "<x> <y> <w> <h> <class> <pid> <workspace>"
  [[ -n $1 ]] || return 0
  hypr -j clients | jq -r --arg a "$1" '.[] | select(.address == $a) | "\(.at[0]) \(.at[1]) \(.size[0]) \(.size[1]) \(.class) \(.pid) \(.workspace.name)"' | head -n 1
}
# Fraction of a window's inner region (its box less $inset) within 8 % of <colour>.
region_frac() { # <png> <address> <#rrggbb>
  local x y w h geometry
  read -r x y w h _ < <(client_info "$2")
  [[ ${h:-} =~ ^[0-9]+$ ]] || { echo error; return; }
  geometry=$(awk -v x="$x" -v y="$y" -v w="$w" -v h="$h" -v mx="$mon_x" -v my="$mon_y" -v s="$mon_scale" -v i="$inset" \
    'BEGIN { printf "%dx%d+%d+%d", (w - 2 * i) * s, (h - 2 * i) * s, (x - mx + i) * s, (y - my + i) * s }')
  magick "$1" -crop "$geometry" +repage -alpha off -colorspace sRGB -type TrueColor -fuzz 8% -fill "#010203" -opaque "$3" -fuzz 0 \
    -fill black +opaque "#010203" -fill white -opaque "#010203" -format '%[fx:mean]' info: 2>/dev/null || echo error
}
# Standard deviation (0..1, grey) of the middle of a window's titlebar: its title's text, or a flat bar.
bar_spread() { # <png> <address>
  local x y w geometry
  read -r x y w _ < <(client_info "$2")
  [[ ${w:-} =~ ^[0-9]+$ ]] || { echo error; return; }
  geometry=$(awk -v x="$x" -v y="$y" -v w="$w" -v mx="$mon_x" -v my="$mon_y" -v s="$mon_scale" -v bh="$GF_TB_HEIGHT" \
    'BEGIN { printf "%dx%d+%d+%d", (w * 0.4) * s, (bh - 12) * s, (x - mx + w * 0.3) * s, (y - my - bh + 6) * s }')
  magick "$1" -crop "$geometry" +repage -alpha off -colorspace Gray -format '%[fx:standard_deviation]' info: 2>/dev/null || echo error
}
above() { [[ $1 =~ ^[0-9.e+-]+$ ]] && awk -v a="$1" -v b="$2" 'BEGIN { exit !(a + 0 > b + 0) }'; } # <value> <minimum>
below() { [[ $1 =~ ^[0-9.e+-]+$ ]] && awk -v a="$1" -v b="$2" 'BEGIN { exit !(a + 0 < b + 0) }'; } # <value> <maximum>

# ---- the fixture windows (foot's colour options as lock_privacy.sh detects them) ----

foot_check() { env -u WAYLAND_DISPLAY timeout -k 2 10 "$root/scripts/dev/isolated.sh" foot --check-config "$@" >/dev/null 2>&1; }
foot_style=""
if foot_check -o colors-dark.background=000000 -o colors-light.background=000000; then
  foot_style=dark-light
elif foot_check -o colors.background=000000; then
  foot_style=legacy
else
  echo "capture_privacy: foot accepts neither [colors-dark] nor [colors] colour overrides" >&2
  exit 2
fi
colour_opts() { # <rrggbb>: sets opts
  if [[ $foot_style == dark-light ]]; then
    opts=(-o "colors-dark.background=$1" -o "colors-dark.foreground=$1" -o colors-dark.alpha=1 -o "colors-light.background=$1" -o "colors-light.foreground=$1" -o colors-light.alpha=1)
  else
    opts=(-o "colors.background=$1" -o "colors.foreground=$1" -o colors.alpha=1)
  fi
}
win_addr=""
foot_window() { # <app id> <rrggbb> <x> <y> (logical px of $out): sets win_addr, or why
  local opts addr="" x="" y="" tx=$((mon_x + $3)) ty=$((mon_y + $4))
  win_addr=""
  hypr -j clients | jq -e --arg c "$1" 'any(.[]; .class == $c)' >/dev/null && { why="a $1 window is already open (restart the nested session)"; return 1; }
  colour_opts "$2"
  pointer abs $(($3 + win_w / 2)) $(($4 + win_h / 2))
  env WAYLAND_DISPLAY="$sock" HYPRLAND_INSTANCE_SIGNATURE="$sig" setsid "$root/scripts/dev/isolated.sh" foot --app-id="$1" \
    --window-size-pixels="${win_w}x${win_h}" "${opts[@]}" -- sh -c 'printf "\033[?25l"; exec sleep 3600' >/dev/null 2>&1 </dev/null &
  pids+=($!)
  for _ in $(seq 1 40); do
    addr=$(hypr -j clients | jq -r --arg c "$1" '[.[] | select(.class == $c)] | first | .address // empty')
    [[ -n $addr ]] && break
    sleep 0.25
  done
  [[ -n $addr ]] || { why="no $1 window appeared"; return 1; }
  nestctl dispatch "hl.dsp.window.move({ x = $tx, y = $ty, window = 'address:$addr' })" >/dev/null 2>&1
  local moved=0
  for _ in $(seq 1 20); do
    read -r x y _ < <(client_info "$addr")
    [[ ${x:-} =~ ^-?[0-9]+$ && ${y:-} =~ ^-?[0-9]+$ ]] && ((x - tx <= 2 && tx - x <= 2 && y - ty <= 2 && ty - y <= 2)) && { moved=1; break; }
    sleep 0.15
  done
  ((moved)) || { why="the $1 window did not move to ($3,$4) of $out (at ${x:-?},${y:-?} in layout px, target $tx,$ty)"; return 1; }
  win_addr=$addr
}
close_window() { # <address>: closed, and gone from Hyprland's list within 5 s
  nestctl dispatch "hl.dsp.window.close({ window = 'address:$1' })" >/dev/null 2>&1
  for _ in $(seq 1 25); do
    [[ -z $(client_info "$1") ]] && return 0
    sleep 0.2
  done
  return 1
}

# ---- setup ----
say "capture_privacy: $out ${mon_w}x${mon_h} at ${mon_x},${mon_y} scale $mon_scale, nested pid $hypr_pid, run $run"
say "setup"
gap=$(((mon_w - 2 * win_w) / 3)) wy=$(((mon_h - win_h) / 2))
((gap >= 48)) || { echo "capture_privacy: $out is too narrow for two ${win_w}px windows" >&2; exit 2; }
x_twin=$gap x_bw=$((2 * gap + win_w))

foot_window gf-capture-cyan 00ffff "$x_twin" "$wy" || { harness "setup: cyan control window: $why"; exit 2; }
cyan_ctl=$win_addr
sleep 0.8
grab "$run/selfcheck.png" || { harness "setup: no capture of $out"; exit 2; }
c=$(count_colour "$run/selfcheck.png" "$cyan")
above "$c" 50000 || { harness "setup: an unprotected cyan window is not captured cyan ($c px): the detector would prove nothing"; exit 2; }
pass "setup: an unprotected cyan window is captured cyan ($c px): the detector works"
close_window "$cyan_ctl" || { harness "setup: the cyan control window did not close"; exit 2; }
sleep 0.5

foot_window gf-capture-twin 00ff00 "$x_twin" "$wy" || { harness "setup: twin: $why"; exit 2; }
twin=$win_addr
foot_window Bitwarden 00ffff "$x_bw" "$wy" || { harness "setup: Bitwarden: $why"; exit 2; }
bw=$win_addr
prop=$(nestctl getprop "address:$bw" no_screen_share 2>/dev/null | head -n 1)
[[ $prop == *true* || $prop == 1 ]] || { harness "setup: Hyprland does not report no_screen_share for the Bitwarden window ($prop): privacy.lua not applied"; exit 2; }
pass "setup: twin (green, unprotected) and Bitwarden (cyan, no_screen_share $prop) open"
sleep 1

# ---- still ----
say "still"
if grab "$run/still.png"; then
  c=$(count_colour "$run/still.png" "$cyan")
  [[ $c == 0 ]] && pass "still: no cyan px of the Bitwarden window in the capture" || fail "still: $c cyan px of the Bitwarden window captured (SEC-01)"
  g=$(region_frac "$run/still.png" "$twin" "$green")
  above "$g" 0.9 && pass "still: the twin is captured green ($g of its region)" || fail "still: the twin is not captured green ($g): the cyan check proves nothing"
  st=$(bar_spread "$run/still.png" "$twin")
  sb=$(bar_spread "$run/still.png" "$bw")
  above "$st" 0.02 && pass "still: the twin's bar shows its title (spread $st)" || harness "still: no title found on the twin's bar (spread $st): the title check proves nothing"
  below "$sb" 0.01 && pass "still: the Bitwarden bar shows no title in the capture (spread $sb)" || fail "still: the Bitwarden bar is not flat in the capture (spread $sb): its title is captured (SEC-01)"
else
  fail "still: no capture of $out"
fi

# ---- overview ----
say "overview"
n_open=$(grep -c '"type":"overview","state":"open"' "$events")
ipc overview open >/dev/null
opened=0
for _ in $(seq 1 40); do
  (($(grep -c '"type":"overview","state":"open"' "$events") > n_open)) && { opened=1; break; }
  sleep 0.1
done
if ((opened)); then
  sleep 0.6
  if grab "$run/overview.png"; then
    c=$(count_colour "$run/overview.png" "$cyan")
    g=$(count_colour "$run/overview.png" "$green")
    [[ $c == 0 ]] && pass "overview: no cyan px of the Bitwarden miniature captured" || fail "overview: $c cyan px of the Bitwarden miniature captured (SEC-01)"
    above "$g" 2000 && pass "overview: the twin's miniature is captured green ($g px)" || fail "overview: the twin's miniature is not captured ($g green px): the cyan check proves nothing"
  else
    fail "overview: no capture of $out"
  fi
else
  harness "overview: the plugin posted no overview \"open\" event after \`qs ipc call overview open\` ($(grep '"type":"overview"' "$events" | tail -n 1))"
fi
ipc overview close >/dev/null
sleep 1

# ---- stages (the strip stand-in, as soak.sh stages) ----
say "stages"
st_state() { nestctl grassfield-stages 2>/dev/null; }
strip_json=$(jq -nc --argjson x "$mon_x" --argjson y "$mon_y" '{x: $x, y: ($y + 60), w: 220, h: 860}')
tiles_json=$(jq -nc --argjson x "$mon_x" --argjson y "$mon_y" '[range(0; 4) as $i | {x: ($x + 16), y: ($y + 100 + $i * 190), w: 188, h: 160}]')
fixlog=$run/stages-fixture.log
GF_STAGES_OUTPUT=$out GF_STAGES_STRIP=$strip_json GF_STAGES_TILES=$tiles_json WAYLAND_DISPLAY=$sock HYPRLAND_INSTANCE_SIGNATURE=$sig \
  setsid "$root/scripts/dev/isolated.sh" --name stages-fixture qs -p "$root/tests/compositor/stages-fixture" --no-color >"$fixlog" 2>&1 </dev/null &
fixture_pid=$!
for _ in $(seq 1 50); do grep -q "\[stages-fixture\] output $out found" "$fixlog" 2>/dev/null && break; sleep 0.1; done
if grep -q "\[stages-fixture\] output $out found" "$fixlog"; then
  sleep 0.5
  nestctl dispatch 'hl.plugin.grassfield.config("stagesEnabled", "true")' >/dev/null 2>&1
  nestctl dispatch "hl.plugin.grassfield.stages([[$(jq -nc --arg o "$out" --argjson t "$tiles_json" '{op: "on", durationMs: 350, strips: [{monitor: $o, tiles: $t}]}')]])" >/dev/null 2>&1
  sleep 0.5
  nestctl dispatch "hl.plugin.grassfield.stages([[{\"op\":\"move\",\"address\":\"$twin\",\"stage\":\"new\"}]])" >/dev/null 2>&1
  nestctl dispatch "hl.plugin.grassfield.stages([[{\"op\":\"move\",\"address\":\"$bw\",\"stage\":\"new\"}]])" >/dev/null 2>&1
  sleep 1.5
  in_strip=$(st_state | jq -r --arg t "$twin" --arg b "$bw" '[.. | strings | select(. == $t or . == $b or ("0x" + .) == $t or ("0x" + .) == $b)] | length' 2>/dev/null)
  if [[ $(st_state | jq -r '.on') == true ]]; then
    if grab "$run/stages.png"; then
      c=$(count_colour "$run/stages.png" "$cyan")
      g=$(count_colour "$run/stages.png" "$green")
      [[ $c == 0 ]] && pass "stages: no cyan px of the Bitwarden strip tile captured" || fail "stages: $c cyan px of the Bitwarden strip tile captured (SEC-01)"
      above "$g" 1000 && pass "stages: the twin's strip tile is captured green ($g px)" \
        || fail "stages: the twin's strip tile is not captured ($g green px; windows named in the Stages state: ${in_strip:-?}): the cyan check proves nothing"
    else
      fail "stages: no capture of $out"
    fi
  else
    harness "stages: Stages did not turn on ($(st_state | head -c 300))"
  fi
  nestctl dispatch 'hl.plugin.grassfield.stages([[{"op":"off","durationMs":0}]])' >/dev/null 2>&1
  nestctl dispatch 'hl.plugin.grassfield.config("stagesEnabled", "false")' >/dev/null 2>&1
else
  harness "stages: the strip stand-in did not start ($fixlog)"
fi
kill "$fixture_pid" 2>/dev/null
fixture_pid=""
sleep 1.5

# ---- minimize (slow motion, as genie.sh) ----
say "minimize"
# Captures <delays> ms after the click (each grim adds its own start-up) into $run/<prefix>-<ms>.png.
captures_after() { # <prefix> <delays...>
  local prefix=$1 d shots=()
  shift
  for d in "$@"; do
    (sleep "$((d / 1000)).$(printf '%03d' $((d % 1000)))" && nested timeout -k 2 10 grim -o "$out" "$run/$prefix-$d.png" 2>>"$log") &
    shots+=($!)
  done
  wait "${shots[@]}"
}
minimize_slow() { # <address> <prefix>: Shift-click on its minimize light, captures during the animation
  local x y w h
  read -r x y w h _ < <(client_info "$1")
  [[ ${h:-} =~ ^[0-9]+$ ]] || return 1
  local px=$((x - mon_x + GF_TB_MIN_X)) py=$((y - mon_y - GF_TB_MID))
  pointer abs "$px" "$py" sleep 300
  hold_shift 1500
  sleep 0.1
  pointer abs "$px" "$py" sleep 40 click
  captures_after "$2" 400 1200 2000 2800 3600
}
on_minimized() { [[ $(client_info "$1" | awk '{print $7}') == special:minimized ]]; }
minimize_slow "$bw" bw-min
sleep 1
if on_minimized "$bw"; then
  worst=0 shots=0
  for f in "$run"/bw-min-*.png; do
    [[ -s $f ]] || continue
    shots=$((shots + 1))
    c=$(count_colour "$f" "$cyan")
    [[ $c =~ ^[0-9]+$ ]] || c=999999
    ((c > worst)) && worst=$c
  done
  ((shots >= 3)) || harness "minimize: only $shots capture(s) during the Bitwarden animation"
  ((shots >= 3 && worst == 0)) && pass "minimize: no cyan px in $shots captures of the Bitwarden minimize animation"
  ((worst > 0)) && fail "minimize: $worst cyan px of the Bitwarden minimize animation captured (SEC-01)"
else
  harness "minimize: the Bitwarden window was not minimized ($(client_info "$bw"))"
fi
minimize_slow "$twin" twin-min
sleep 1
if on_minimized "$twin"; then
  best=0
  for f in "$run"/twin-min-*.png; do
    [[ -s $f ]] || continue
    g=$(count_colour "$f" "$green")
    [[ $g =~ ^[0-9]+$ ]] && ((g > best)) && best=$g
  done
  ((best >= 500)) && pass "minimize: the twin's animation is captured (up to $best green px): the cyan check sees animations" \
    || fail "minimize: the twin's animation is not in the captures (up to $best green px): the cyan check proves nothing"
else
  harness "minimize: the twin was not minimized ($(client_info "$twin"))"
fi

# ---- health ----
say "health"
kill -0 "$hypr_pid" 2>/dev/null && pass "health: the nested Hyprland is alive" || fail "health: the nested Hyprland is gone"
exc=$(tail -n +"$((log_lines_before + 1))" "$hyprlog" 2>/dev/null | grep -ac '\[grassfield\] .*exception')
[[ $exc == 0 ]] && pass "health: no grassfield exception in the nested log since $started" || fail "health: $exc grassfield exception line(s) in the nested log"

if ((status)); then
  say "capture_privacy: FAIL ($run)"
  exit 1
fi
if ((harness)); then
  say "capture_privacy: HARNESS ERROR: some checks could not run ($run)"
  exit 2
fi
say "capture_privacy: PASS ($run)"
exit 0
