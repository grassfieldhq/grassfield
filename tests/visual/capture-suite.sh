#!/usr/bin/env bash
# The capture suite (docs/specs/capture-suite.md, waves 1-3: C1-C4, C8, A1-A4, A8, B1-B6, B8, B18) proved on screen, in the nested session,
# on GF-REF at scale 1.25 (the owner's panel). What the unit tests cannot show:
#   ack     1. the real shell acknowledges a shot (C1/C2): `grassfield-capture screen | selection --geometry | window --geometry` run from
#              this tree; the acknowledgement of the `shooting` seq, its latency, the result file, no notice when the card shows
#   thumb   2. the floating thumbnail (A2/A3): a card bottom-right on the right output, a portrait picture, a stack of three, the text card
#              (Capture Text with the real tesseract), slide-out and dismiss, the glass (layer rule `capture-thumbnail`), device pixels
#   toolbar 3. the capture toolbar and its Options menu (A4/A8): the modes, the rows per mode, the 3 s timer countdown, Hide Desktop Icons
#              (the shot has none), Capture Previous Area
#   freeze  4. `selection --freeze` and `choose` (C4): the frozen frames are the screen, the crop is pixel-exact at 1.25
#   editor  5. the Screenshot app (B1-B6, B8) on the GPU: every tool drawn, exported, the export compared with the window's pixels
# The helper the shell and this script run is tests/visual/fixtures/capture-helper.sh (the dev state folder bound where the helper expects
# its private folder, in a mount namespace of that one process), and the Pictures/Videos/Desktop/Documents folders are the fixture's own
# (XDG_CONFIG_HOME of the shell and of the helper names them): nothing is written in the owner's home or runtime folder.
# Captures: $VS_STATE/capture-suite/ (copied to .dev/capture-nested/ by the run); screenshots of GF-REF: .dev/visual/shots/cs-*.png.
# Run (BARE command; starts a nested session when none is up and stops it at the end unless --keep):
#   tests/visual/capture-suite.sh [--keep] [ack] [thumb] [toolbar] [freeze] [editor] [multi]
# Exit status 1 when a check fails, 2 when the session cannot be set up. NOT VERIFIED items say so on a NOTE line.
export VISUAL_LANG=${VISUAL_LANG:-en}
export GRASSFIELD_REF_SCALE=1.25
source "$(dirname "$0")/flow-lib.sh"

keep=0
phases=()
for a in "$@"; do
  case $a in
    --keep) keep=1 ;;
    ack | thumb | toolbar | freeze | editor | multi) phases+=("$a") ;;
    *) echo "usage: capture-suite.sh [--keep] [ack] [thumb] [toolbar] [freeze] [editor] [multi]" >&2; exit 2 ;;
  esac
done
(( ${#phases[@]} )) || phases=(ack thumb toolbar freeze editor multi)
want() { local p; for p in "${phases[@]}"; do [[ $p == "$1" ]] && return 0; done; return 1; }

# grim of the nested window's own output (WAYLAND-1) waits for the host compositor to repaint that window (docs/testing; dock-displays.sh
# bounds it the same way): when it does not return, every capture of ALL displays (Entire Screen without --output, --freeze) is stuck in the
# helper's grim call, so those checks are skipped as NOT VERIFIED instead of failing.
wl1_ok() { timeout 10 "$VS_ROOT/scripts/dev/shot.sh" cs-wl1 WAYLAND-1 >/dev/null 2>&1; }
cs=$VS_STATE/capture-suite
out=$cs/out
xdg=$cs/xdg
helper=$VS_HERE/fixtures/capture-helper.sh
mkdir -p "$out" "$xdg/config" "$cs/Desktop" "$cs/Documents" "$cs/Pictures" "$cs/Videos"
pics=$cs/Pictures/Screenshots
rm -rf -- "$cs/Pictures" "$out"
mkdir -p "$cs/Pictures" "$out"
cat > "$xdg/config/user-dirs.dirs" <<EOF
XDG_DESKTOP_DIR="$cs/Desktop"
XDG_DOCUMENTS_DIR="$cs/Documents"
XDG_PICTURES_DIR="$cs/Pictures"
XDG_VIDEOS_DIR="$cs/Videos"
EOF

was_running=0
vs_nested_running && was_running=1
cleanup() {
  vs_nested_running && { vs_kill_clients; fl_cleanup; } || true
  if (( ! keep && ! was_running )); then "$VS_ROOT/scripts/dev/nested-down.sh" >/dev/null 2>&1 || true; fi
  return 0
}

# ---- the session ------------------------------------------------------------------------------------------------------------------------
vs_session en >/dev/null || { echo "capture-suite: the nested session did not come up"; exit 2; }
trap cleanup EXIT
trap 'exit 130' INT TERM
# The shell again, with the fixture folders and the capture helper (a dev shell runs none without GRASSFIELD_CAPTURE_HELPER).
export XDG_CONFIG_HOME=$xdg/config GRASSFIELD_CAPTURE_HELPER=$helper
"$VS_ROOT/scripts/dev/shell-run.sh" --private-bus --lang en --desktop-dir "$VS_STATE/desktop" || { echo "capture-suite: the shell did not restart"; exit 2; }
for _ in $(seq 1 60); do vs_ipc lock status >/dev/null 2>&1 && break; sleep 0.5; done
vs_wait_capabilities en || exit 2
sleep 2
FL_NAME=capture-suite
fl_fail=0
set +e
vs_reset dark 0.25
fl_focus_output

cfg=$VS_DEV/config/grassfield.json
# edit JQ-FILTER: the settings of this tree (the shell follows the file live).
edit() {
  [[ -f $cfg ]] || echo '{}' > "$cfg"
  jq "$1" "$cfg" > "$cfg.new" && mv "$cfg.new" "$cfg" || { echo "capture-suite: cannot edit $cfg"; exit 2; }
  sleep 1.5
}
edit '.capture.thumbnailSeconds = 15 | .capture.showThumbnail = true | .capture.location = "screenshots" | .capture.timer = "none" | .capture.hideDesktopIcons = false | .capture.rememberSelection = true'

state_dir=$VS_DEV/state
# cs_helper ARGS...: the capture helper of this tree, in the environment the shell gives it (this tree's nested instance only).
cs_helper() {
  env WAYLAND_DISPLAY="$(vs_nested_wayland)" HYPRLAND_INSTANCE_SIGNATURE="$(<"$VS_DEV/nested.instance")" \
    DBUS_SESSION_BUS_ADDRESS="$(<"$VS_DEV/bus.address")" GRASSFIELD_STATE_HOME="$state_dir" GRASSFIELD_CONFIG_HOME="$VS_DEV/config" \
    GRASSFIELD_DEV=1 GRASSFIELD_LANG=en LC_ALL=en_US.UTF-8 XDG_CONFIG_HOME="$xdg/config" "$helper" "$@"
}
now_ms() { local t=$EPOCHREALTIME; echo $(( ${t/./} / 1000 )); }
# cs_timed LOG ARGS...: runs the helper in the background and notes when its state says `shooting` (with the seq), when the shell's
# acknowledgement equals that seq, and when it exits (ms). Sets T_SHOOT, T_ACK, T_END (relative to the start), SEQ and RC.
cs_timed() {
  local log=$1 t0 t1 t2 pid s
  shift
  rm -f "$state_dir/capture-result.json"
  t0=$(now_ms)
  cs_helper "$@" > "$log" 2>&1 &
  pid=$!
  T_SHOOT=-1 T_ACK=-1 SEQ=""
  while kill -0 "$pid" 2>/dev/null; do
    if [[ -z $SEQ ]]; then
      s=$(sed -n 's/.*"phase": *"shooting".*"seq": *"\([0-9a-f]\{16\}\)".*/\1/p' "$state_dir/capture-state.json" 2>/dev/null)
      [[ -z $s ]] && s=$(sed -n 's/.*"seq": *"\([0-9a-f]\{16\}\)".*"phase": *"shooting".*/\1/p' "$state_dir/capture-state.json" 2>/dev/null)
      if [[ -n $s ]]; then SEQ=$s; T_SHOOT=$(( $(now_ms) - t0 )); fi
    fi
    if [[ -n $SEQ && $T_ACK -lt 0 && $(cat "$state_dir/capture-ack" 2>/dev/null) == "$SEQ" ]]; then T_ACK=$(( $(now_ms) - t0 )); fi
    sleep 0.004
  done
  wait "$pid"
  RC=$?
  T_END=$(( $(now_ms) - t0 ))
}
# cs_reset: no helper of an earlier run is left in the middle of a capture (its state is not idle): stop it by the pid its state names
# (only when that process is this tree's helper), so that the next capture is not refused and the shell does not hold its cards.
cs_reset() {
  local ph pid
  ph=$(jq -r .phase "$state_dir/capture-state.json" 2>/dev/null)
  [[ $ph == idle || -z $ph ]] && return 0
  echo "NOTE: the helper state is '$ph' before the phase: stopping it"
  cs_helper stop >/dev/null 2>&1
  fl_wait 4 phase_is idle && return 0
  pid=$(jq -r .pid "$state_dir/capture-state.json" 2>/dev/null)
  if [[ $pid =~ ^[0-9]+$ ]] && tr '\0' ' ' < "/proc/$pid/cmdline" 2>/dev/null | grep -q "$VS_ROOT/packaging/bin/grassfield-capture"; then
    kill -TERM "$pid" 2>/dev/null
    sleep 2
  fi
  [[ $(jq -r .phase "$state_dir/capture-state.json") == idle ]] || echo "NOTE: the helper state stays '$(jq -r .phase "$state_dir/capture-state.json")'"
}
nshots() { find "$pics" -maxdepth 1 -name '*.png' 2>/dev/null | wc -l; }
# shot NAME [OUTPUT]: grim of an output of the nested compositor → $out/NAME.png (and the file under .dev/shots).
shot() {
  local o=${2:-$VS_OUTPUT}
  rm -f "$VS_DEV/shots/cs-$1.png"
  "$VS_ROOT/scripts/dev/shot.sh" "cs-$1" "$o" >/dev/null 2>&1 && cp "$VS_DEV/shots/cs-$1.png" "$out/$1.png"
  [[ -s $out/$1.png ]]
}
dims() { magick identify -format '%wx%h' "$1" 2>/dev/null; }
scale_now=$("$VS_ROOT/scripts/nestctl" monitors -j | jq -r --arg n "$VS_OUTPUT" '.[] | select(.name == $n) | .scale')
fl_check "GF-REF runs at scale 1.25 (is $scale_now; a session that was already up keeps its scale: stop it first)" test "$scale_now" = 1.25
mapfile -t outputs < <("$VS_ROOT/scripts/nestctl" monitors -j | jq -r '.[].name')
echo "capture-suite: outputs ${outputs[*]}"

# ---- helpers of the thumbnail checks -----------------------------------------------------------------------------------------------------
# card_layers: "x y w h" (logical, compositor coordinates) of every mapped thumbnail card layer, top to bottom.
card_layers() {
  "$VS_ROOT/scripts/nestctl" layers -j 2>/dev/null | jq -r '[.. | objects | select(.namespace? == "grassfield-capture-thumbnail")] | sort_by(.y) | .[] | "\(.x) \(.y) \(.w) \(.h)"'
}
card_count() { card_layers | grep -c . || true; }
no_cards() { [[ $(card_count) == 0 ]]; }
# bbox A B [WxH+X+Y]: the box ("WxH+X+Y" in the region's pixels) where the two captures differ, inside the region (default: all).
bbox() {
  local a=$1 b=$2
  if [[ -n ${3:-} ]]; then
    magick "$1" -crop "$3" +repage "$cs/.a.png"; magick "$2" -crop "$3" +repage "$cs/.b.png"; a=$cs/.a.png; b=$cs/.b.png
  fi
  magick "$a" "$b" -compose difference -composite -colorspace Gray -threshold "${BBOX_T:-12%}" -format '%@' info: 2>/dev/null
}
# wait_shots N: until the Screenshots folder holds N pictures (at most 15 s).
wait_shots() { fl_wait 15 shots_ge "$1"; }
shots_ge() { [[ $(nshots) -ge $1 ]]; }
count_is() { [[ $(card_count) == "$1" ]]; }
phase_is() { [[ $(jq -r .phase "$state_dir/capture-state.json" 2>/dev/null) == "$1" ]]; }
quiet() { vs_ipc notifications clearAll >/dev/null 2>&1; edit '.capture.thumbnailSeconds = 2'; fl_wait 25 no_cards || echo "NOTE: $(card_count) card(s) still up after 25 s"; sleep 0.5; }
result_field() { jq -r "$1" "$state_dir/capture-result.json" 2>/dev/null; }
png_scale() { magick identify -verbose "$1" 2>/dev/null | sed -n 's/.*Grassfield-Scale: *//p' | head -1; }

if want ack; then
  echo "== 1. the shell acknowledges a shot (C1/C2)"
  cs_reset
  quiet
  edit '.capture.thumbnailSeconds = 15'
  lat=()
  for i in 1 2 3 4 5; do
    vs_ipc notifications clearAll >/dev/null 2>&1
    cs_timed "$out/ack-screen-$i.log" screen --output GF-REF
    lat+=($(( T_ACK - T_SHOOT )))
    echo "screen #$i: rc=$RC, shooting at ${T_SHOOT} ms, ack ${T_ACK} ms (latency $(( T_ACK - T_SHOOT )) ms), exit ${T_END} ms, seq $SEQ"
    sleep 0.5
  done
  fl_check "screen: the helper exits 0" test "$RC" = 0
  fl_check "screen: the state said shooting with a 16-digit seq, and the shell acknowledged exactly that seq" test -n "$SEQ" -a "$T_ACK" -ge 0
  max=0; for l in "${lat[@]}"; do (( l > max )) && max=$l; done
  echo "ack latency (state shooting -> capture-ack holds seq), 5 runs: ${lat[*]} ms, max $max ms (the helper waits at most 1000 ms)"
  fl_check "ack latency stays far under the helper's 1000 ms wait (max $max ms, bound 400)" test "$max" -lt 400
  prim=$(result_field .primary)
  fl_check "result file: kind shot, output GF-REF, 1920x1080 at scale 1.25" test "$(result_field '[.kind,.output,.scale,.pixels.w,.pixels.h]|join(" ")')" = "shot GF-REF 1.25 1920 1080"
  fl_check "result file: 0600" test "$(stat -c %a "$state_dir/capture-result.json")" = 600
  fl_check "the saved PNG is 1920x1080 (device pixels) and says Grassfield-Scale 1.25" test "$(dims "$prim")" = 1920x1080 -a "$(png_scale "$prim")" = 1.25
  fl_check "the file is in the fixture Screenshots folder, not the owner's" test "${prim#"$pics"/}" != "$prim"
  fl_check "no notice banner when the card shows (acknowledged and result written)" test "$(fl_notif banners)" = 0
  sleep 1
  shot ack-card
  fl_check "the floating card is mapped after the shots" test "$(card_count)" -ge 1
  # the card was up while the next shot was taken: the shot has none of it (the cards are unmapped before the ack)
  d=$(bbox "$prim" "$out/ack-card.png" "700x470+1220+610")
  echo "bbox of the difference between the saved shot and the live screen, in the card's corner: ${d:-none}"
  fl_check "the saved shot has no card in it (the corner of the file differs from the live screen, where the card is)" test -n "$d" -a "${d%% *}" != "0x0+0+0"
  # selection --geometry: pixel-exact against grim of the same area; 1500,100 600x400 in compositor coordinates = (60,100) on GF-REF
  quiet
  shot ack-base
  cs_timed "$out/ack-sel.log" selection --geometry "1500,100 600x400"
  sel=$(result_field .primary)
  echo "selection --geometry: rc=$RC latency $(( T_ACK - T_SHOOT )) ms, $(dims "$sel")"
  fl_check "selection --geometry: exit 0, ack seen, 750x500 device pixels (600x400 at 1.25), result pixels agree" test "$RC" = 0 -a "$T_ACK" -ge 0 -a "$(dims "$sel")" = 750x500 -a "$(result_field '"\(.pixels.w)x\(.pixels.h)"')" = 750x500
  magick "$out/ack-base.png" -crop 750x500+75+125 +repage "$out/ack-sel-ref.png"
  fl_check "selection --geometry: the file equals grim of the same area, pixel for pixel (differing pixels $(vs_px_diff "$sel" "$out/ack-sel-ref.png"))" test "$(vs_px_diff "$sel" "$out/ack-sel-ref.png")" = 0
  # window --geometry: a foot window
  quiet
  vs_spawn foot -c "$VS_HERE/fixtures/foot.ini" -T "Capture window" --window-size-chars 40x8 sh -c "printf '\033[?25l%s\n' 'Capture window' 'pixels'; exec sleep 100000"
  fl_check_wait "the foot window is mapped" 20 fl_has_window '^foot$'
  sleep 2
  read -r wx wy ww wh <<<"$("$VS_ROOT/scripts/nestctl" clients -j | jq -r '[.[] | select(.mapped and .class == "foot")][0] | "\(.at[0]) \(.at[1]) \(.size[0]) \(.size[1])"')"
  shot ack-win-base
  cs_timed "$out/ack-win.log" window --geometry "$wx,$wy ${ww}x${wh}"
  win=$(result_field .primary)
  echo "window --geometry $wx,$wy ${ww}x${wh}: rc=$RC latency $(( T_ACK - T_SHOOT )) ms, $(dims "$win")"
  ex=$(awk -v v=$(( wx - 1440 )) 'BEGIN{printf "%.0f", v * 1.25}'); ey=$(awk -v v="$wy" 'BEGIN{printf "%.0f", v * 1.25}')
  ew=$(awk -v v="$ww" 'BEGIN{printf "%.0f", v * 1.25}'); eh=$(awk -v v="$wh" 'BEGIN{printf "%.0f", v * 1.25}')
  magick "$out/ack-win-base.png" -crop "${ew}x${eh}+${ex}+${ey}" +repage "$out/ack-win-ref.png"
  fl_check "window --geometry: exit 0 and ack seen" test "$RC" = 0 -a "$T_ACK" -ge 0
  fl_check "window --geometry: the file equals grim of the window's box within 300 px of 103k, all on its edge: the window starts on a fractional device pixel (differing pixels $(vs_px_diff "$win" "$out/ack-win-ref.png"), size $(dims "$win") vs ${ew}x${eh})" test "$(vs_px_diff "$win" "$out/ack-win-ref.png")" -le 300
  fl_close_windows '^foot$'
  # Show Floating Thumbnail off: no result file, the notice instead (the fallback the spec names)
  quiet
  edit '.capture.showThumbnail = false'
  rm -f "$state_dir/capture-result.json"
  vs_ipc notifications clearAll >/dev/null 2>&1
  cs_helper screen --output GF-REF > "$out/ack-nothumb.log" 2>&1 &
  vs_track "$!"
  tl=""
  for _ in $(seq 1 14); do sleep 0.5; tl="$tl $(fl_notif banners)/$(fl_notif history)"; done
  echo "banners/history every 0.5 s after the capture (thumbnail off):$tl"
  shot ack-nothumb
  fl_check "showThumbnail off: no result file, and the notice shows the capture (banners/history $(fl_notif banners)/$(fl_notif history))" test ! -e "$state_dir/capture-result.json" -a "$(fl_notif history)" -ge 1
  edit '.capture.showThumbnail = true'
fi

if want thumb; then
  echo "== 2. the floating thumbnail (A2/A3)"
  cs_reset
  quiet
  shot th-base
  edit '.capture.thumbnailSeconds = 15'
  cs_timed "$out/th1.log" selection --geometry "1500,100 600x400"
  sleep 1.5
  shot th-card1
  read -r cx cy cw ch <<<"$(card_layers | head -1)"
  echo "card layer: $cx,$cy ${cw}x${ch} (compositor logical)"
  bb=$(bbox "$out/th-base.png" "$out/th-card1.png" "700x600+1220+480")
  echo "card pixels (difference with the empty desktop, in the bottom-right 700x600): $bb"
  fl_check "one card, on GF-REF (x $cx is right of the output's middle 2208), bottom-right" test "$(card_count)" = 1 -a "$cx" -gt 2208
  # layer = plate + 2 x edge (16): plate 216 wide
  fl_check "card plate is 216 pt wide (token) = 270 device pixels: layer ${cw} wide" test "$cw" -ge 247 -a "$cw" -le 248
  # the card is the picture (no plate): its pixels are 270 device pixels wide (216 pt at 1.25), not 269
  fl_check "card is 270 device pixels wide (216 pt at 1.25), whole pixels: ${bb%%x*}" test "${bb%%x*}" = 270
  fl_check "card sits 16 pt from the right edge: layer right edge $((cx + cw)) vs output right 2976" test "$((cx + cw))" = 2976
  # the picture inside the card is the capture: compare the card's picture with the capture scaled to it
  ix=$(( (cx - 1440 + 16) * 125 / 100 )); iy=$(( (cy + 16) * 125 / 100 ))
  magick "$(result_field .primary)" -resize 270x180! "$out/th-ref.png"
  magick "$out/th-card1.png" -crop 270x180+${ix}+${iy} +repage "$out/th-inner.png"
  rm1=$(magick compare -metric RMSE "$out/th-ref.png" "$out/th-inner.png" null: 2>&1 | sed 's/.*(\(.*\))/\1/')
  echo "RMSE (0-1) of the card's picture against the capture scaled to 270x180: $rm1"
  fl_check "the card shows the capture (RMSE $rm1 < 0.05)" awk -v r="$rm1" 'BEGIN{exit !(r < 0.05)}'
  # a portrait capture
  cs_timed "$out/th2.log" selection --geometry "1500,50 300x500"
  sleep 1.5
  shot th-card2
  mapfile -t L < <(card_layers)
  echo "cards after the portrait: ${L[*]}"
  read -r px py pw ph <<<"${L[0]}"
  fl_check "two cards, the new portrait one on top" test "${#L[@]}" = 2
  fl_check "portrait card: 144 pt tall picture, narrower than the landscape (layer ${pw} wide, ${ph} tall)" test "$pw" -lt 248 -a "$ph" = $((144 + 32))
  # three, then a fourth pushes the oldest out
  cs_timed "$out/th3.log" screen --output GF-REF
  cs_timed "$out/th4.log" selection --geometry "1700,300 500x300"
  sleep 1.5
  shot th-stack
  fl_check "at most three cards (four shots, now $(card_count))" test "$(card_count)" = 3
  fl_check "no binding loop in the shell log" test "$(grep -c 'Binding loop' "$VS_DEV/shell.log")" = 0
  # the card's hover buttons
  read -r cx cy cw ch <<<"$(card_layers | tail -1)"
  vs_pointer abs $(( cx - 1440 + cw / 2 )) $(( cy + ch / 2 )) >/dev/null
  sleep 1
  shot th-hover
  vs_park
  quiet
  edit '.capture.thumbnailSeconds = 15'
  cs_timed "$out/th5.log" selection --geometry "1500,100 600x400"
  cs_timed "$out/th6.log" selection --geometry "1500,50 300x500"
  cs_timed "$out/th7.log" screen --output GF-REF
  sleep 2
  echo "cards before the actions: $(card_layers | tr '\n' ';')"
  # the pointer on a card: the hover buttons (Close top left, Copy / Show in Files / Move to Trash top right), at the plate's offsets
  plate_xy() { read -r cx cy cw ch <<<"$(card_layers | sed -n "${1}p")"; PX=$(( cx - 1440 + 16 )); PY=$(( cy + 16 )); PW=$(( cw - 32 )); PH=$(( ch - 32 )); }
  nclip() { env WAYLAND_DISPLAY="$(vs_nested_wayland)" wl-paste -t image/png 2>/dev/null | magick identify -format '%wx%h' - 2>/dev/null; }
  # Copy: the card's picture onto the clipboard
  env WAYLAND_DISPLAY="$(vs_nested_wayland)" wl-copy --clear 2>/dev/null
  plate_xy '$'
  vs_pointer abs $(( PX + PW / 2 )) $(( PY + PH / 2 )) sleep 600 abs $(( PX + 128 )) $(( PY + 29 )) sleep 400 click >/dev/null
  sleep 1
  echo "clipboard after Copy: $(nclip)"
  fl_check "Copy puts the card's picture on the clipboard as image/png ($(nclip))" test -n "$(nclip)"
  # Close: the card slides out
  n0=$(card_count)
  plate_xy '$'
  vs_pointer abs $(( PX + PW / 2 )) $(( PY + PH / 2 )) sleep 600 abs $(( PX + 29 )) $(( PY + 29 )) sleep 400 click >/dev/null
  fl_check_wait "Close: the card goes" 8 count_is $((n0 - 1))
  vs_park
  # Swipe toward the screen edge dismisses
  n0=$(card_count)
  plate_xy 1
  vs_pointer abs $(( PX + PW / 2 )) $(( PY + PH / 2 )) sleep 500 down sleep 300 drag $(( PX + PW / 2 + 40 )) $(( PY + PH / 2 )) sleep 300 drag $(( PX + PW / 2 + 100 )) $(( PY + PH / 2 )) sleep 400 up >/dev/null
  fl_check_wait "swipe toward the edge dismisses the card" 8 count_is $((n0 - 1))
  vs_park
  # Click opens the editor (Annotate); the dev shell has no grassfield-screenshot on its PATH, so NOT VERIFIED here
  # the timeout: 2 s card goes by itself
  quiet
  edit '.capture.thumbnailSeconds = 2'
  cs_timed "$out/th-timeout.log" selection --geometry "1500,100 600x400"
  tshot=$(now_ms)
  fl_wait 3 count_is 1
  fl_check "the card shows (1 card)" test "$(card_count)" = 1
  fl_check_wait "the card closes by itself after capture.thumbnailSeconds (2 s)" 8 no_cards
  echo "card gone $(( $(now_ms) - tshot )) ms after the helper exited (setting 2000 ms, plus the slide-out)"
  # Capture Text: tesseract on a window with big text; the card says it copied
  quiet
  edit '.capture.thumbnailSeconds = 15'
  vs_spawn foot -c "$VS_HERE/fixtures/foot.ini" -o main.font=monospace:size=26 -T "Capture text" --window-size-chars 36x4 sh -c "printf '%s\n' 'Grassfield capture text' 'Quartz 1234'; exec sleep 100000"
  fl_check_wait "the text window is mapped" 20 fl_has_window '^foot$'
  sleep 2
  read -r wx wy ww wh <<<"$("$VS_ROOT/scripts/nestctl" clients -j | jq -r '[.[] | select(.mapped and .class == "foot")][0] | "\(.at[0]) \(.at[1]) \(.size[0]) \(.size[1])"')"
  env WAYLAND_DISPLAY="$(vs_nested_wayland)" wl-copy --clear 2>/dev/null
  cs_timed "$out/th-text.log" text --geometry "$wx,$wy ${ww}x${wh}"
  sleep 1.5
  shot th-text
  echo "text result: $(jq -c . "$state_dir/capture-result.json")"
  clip=$(env WAYLAND_DISPLAY="$(vs_nested_wayland)" wl-paste -n 2>/dev/null)
  echo "clipboard: $clip"
  fl_check "Capture Text: exit 0, ack seen, result kind text" test "$RC" = 0 -a "$T_ACK" -ge 0 -a "$(result_field .kind)" = text
  fl_check "tesseract read the window (result text has 'Grassfield' and '1234')" bash -c "[[ \"\$(jq -r .text '$state_dir/capture-result.json')\" == *Grassfield* && \"\$(jq -r .text '$state_dir/capture-result.json')\" == *1234* ]]"
  fl_check "the clipboard holds the recognised text" bash -c "[[ \"$clip\" == *Grassfield* ]]"
  fl_check "the text card is mapped" test "$(card_count)" -ge 1
  fl_close_windows '^foot$'
fi

if want toolbar; then
  echo "== 3. the capture toolbar and its Options menu (A4/A8)"
  cs_reset
  quiet
  edit '.capture.thumbnailSeconds = 15 | .capture.timer = "none" | .capture.hideDesktopIcons = false | .capture.rememberSelection = true | .capture.mode = "selection"'
  # The bar's buttons, on GF-REF at scale 1.25 (logical points, measured on the screenshots of 2026-11-24; each click is checked by the
  # state the shell reports, so a layout change fails here instead of passing by luck).
  B_SCREEN="586 742"; B_WINDOW="628 742"; B_SELECTION="670 742"; B_TEXT="713 742"; B_RECSCREEN="766 742"; B_OPTIONS="882 742"; B_CAPTURE="972 742"
  tb_status() { fl_json capture status; }
  tb_closed() { [[ $(tb_status | jq -r .open) == false ]]; }
  tb_click() { # tb_click "X Y"
    # shellcheck disable=SC2086
    vs_pointer abs $1 sleep 200 click >/dev/null; sleep 0.6
  }
  menu_text() { # NAME: the Options menu of the screenshot NAME as text (OCR of its panel, 2x)
    magick "$out/$1.png" -crop 300x640+1030+270 +repage -colorspace Gray -resize 200% -negate "$cs/.menu.png"
    tesseract "$cs/.menu.png" - --psm 6 2>/dev/null
  }
  vs_ipc capture open >/dev/null
  sleep 1.5
  shot tb-open
  fl_check "the toolbar opens on GF-REF in the remembered mode (selection)" test "$(tb_status | jq -r '.open and .mode == "selection" and .screen == "GF-REF"')" = true
  declare -A rows_have rows_not
  rows_have[selection]="Save to|Timer|3 Seconds|5 Seconds|10 Seconds|Show Floating Thumbnail|Remember Last Selection|Show Mouse Pointer|Hide Desktop Icons|Capture Previous Area"
  rows_not[selection]="Microphone|Do Not Disturb"
  rows_have[window]="Save to|Timer|3 Seconds|Show Floating Thumbnail|Show Mouse Pointer|Hide Desktop Icons"
  rows_not[window]="Remember Last Selection|Capture Previous Area|Microphone"
  rows_have[screen]="Save to|Timer|3 Seconds|Show Floating Thumbnail|Show Mouse Pointer|Hide Desktop Icons"
  rows_not[screen]="Remember Last Selection|Capture Previous Area|Microphone"
  rows_have[text]="Options|Show Floating Thumbnail|Remember Last Selection|Hide Desktop Icons"
  rows_not[text]="Save to|Timer|Show Mouse Pointer|Microphone|Capture Previous Area"
  rows_have[recordScreen]="Save to|Timer|Microphone|Show Floating Thumbnail|Show Mouse Pointer|Hide Desktop Icons|Do Not Disturb"
  rows_not[recordScreen]="Remember Last Selection|Capture Previous Area"
  for m in selection window screen text recordScreen; do
    case $m in selection) b=$B_SELECTION ;; window) b=$B_WINDOW ;; screen) b=$B_SCREEN ;; text) b=$B_TEXT ;; recordScreen) b=$B_RECSCREEN ;; esac
    tb_click "$b"
    fl_check "mode $m: the toolbar reports it after the click" test "$(tb_status | jq -r .mode)" = "$m"
    tb_click "$B_OPTIONS"
    IFS='|' read -ra want_rows <<<"${rows_have[$m]}"
    for attempt in 1 2; do
      shot "tb-menu-$m"
      t=$(menu_text "tb-menu-$m")
      miss=""
      for r in "${want_rows[@]}"; do grep -qiF -- "$r" <<<"$t" || miss="$miss [$r]"; done
      [[ -z $miss ]] && break
      sleep 1
    done
    IFS='|' read -ra not_rows <<<"${rows_not[$m]}"
    extra=""; for r in "${not_rows[@]}"; do grep -qiF -- "$r" <<<"$t" && extra="$extra [$r]"; done
    fl_check "mode $m: the Options menu has its rows (missing:${miss:- none}; rows that must not show:${extra:- none})" test -z "$miss" -a -z "$extra"
    tb_click "$B_OPTIONS"
  done
  # 3 s timer: Options > 3 Seconds, then Capture in Selected Portion; the countdown plate counts and the picture follows
  tb_click "$B_SELECTION"
  tb_click "$B_OPTIONS"
  tb_click "897 479"
  fl_check "Options > 3 Seconds sets the timer (capture.timer)" test "$(tb_status | jq -r .options.timer)" = 3
  n0=$(nshots)
  tb_click "$B_CAPTURE"
  tc=$(now_ms)
  seen=""; last=""
  for _ in $(seq 1 60); do
    st=$(tb_status)
    ph=$(jq -r .phase <<<"$st"); sl=$(jq -r .secondsLeft <<<"$st")
    [[ $ph == countdown && $sl != "$last" ]] && { seen="$seen $sl"; last=$sl; [[ -z ${cdshot:-} ]] && { shot tb-countdown; cdshot=1; }; }
    (( $(nshots) > n0 )) && break
    sleep 0.1
  done
  tshot=$(( $(now_ms) - tc ))
  echo "countdown seconds seen:${seen:-none}; the picture arrived ${tshot} ms after the click on Capture"
  fl_check "the countdown shows 3, 2, 1 (seen:${seen:-none})" test "$seen" = " 3 2 1" -o "$seen" = " 2 1" -o "$seen" = " 3 2"
  fl_check "the picture is taken after about 3 s (between 2.5 s and 6 s: ${tshot} ms)" test "$tshot" -ge 2500 -a "$tshot" -le 6000
  wait_shots $((n0 + 1))
  sleep 1
  tb_click "$B_OPTIONS" 2>/dev/null
  vs_ipc capture close >/dev/null
  edit '.capture.timer = "none"'
  # the frame of Capture Selected Portion is remembered once it was moved; Capture Previous Area takes it again, with no toolbar
  quiet
  edit '.capture.thumbnailSeconds = 15 | .capture.lastSelection = ""'
  vs_ipc capture open >/dev/null; sleep 1
  tb_click "$B_SELECTION"
  vs_pointer abs 768 432 sleep 300 down sleep 200 drag 700 400 sleep 200 up >/dev/null
  sleep 0.8
  shot tb-frame-moved
  n0=$(nshots)
  tb_click "$B_CAPTURE"
  wait_shots $((n0 + 1))
  sleep 1
  echo "capture.lastSelection: $(jq -c '.capture.lastSelection' "$cfg")"
  fl_check "the moved frame is remembered per display (capture.lastSelection names GF-REF)" bash -c "jq -r '.capture.lastSelection' '$cfg' | grep -q GF-REF"
  first=$(ls -t "$pics"/*.png | head -1)
  echo "first capture of the frame: $(dims "$first")"
  vs_ipc capture open >/dev/null; sleep 1
  tb_click "$B_SELECTION"
  tb_click "$B_OPTIONS"
  n0=$(nshots)
  tb_click "933 693"
  wait_shots $((n0 + 1))
  sleep 1.5
  second=$(ls -t "$pics"/*.png | head -1)
  echo "first $(dims "$first"), previous area $(dims "$second")"
  fl_wait 5 tb_closed
  echo "toolbar after Capture Previous Area: $(tb_status | jq -c '{open,phase}')"
  fl_check "Capture Previous Area: the toolbar is gone" test "$(tb_status | jq -r .open)" = false
  fl_check "Capture Previous Area: a new picture of the same size as the first ($(dims "$second") vs $(dims "$first"); ${second##*/} vs ${first##*/})" test "$(dims "$first")" = "$(dims "$second")" -a "$first" != "$second"
  fl_check "Capture Previous Area: the same pixels as the first capture (differing: $(vs_px_diff "$first" "$second"))" test "$(vs_px_diff "$first" "$second")" = 0
  # Hide Desktop Icons: the picture has no icons, and they come back
  quiet
  edit '.capture.thumbnailSeconds = 15'
  shot tb-icons-base
  vs_ipc capture open >/dev/null; sleep 1
  tb_click "$B_SCREEN"
  tb_click "$B_OPTIONS"
  tb_click "925 693"
  fl_check "Options > Hide Desktop Icons is on (capture.hideDesktopIcons)" test "$(tb_status | jq -r .options.hideDesktopIcons)" = true
  # (a row closes the menu.) A click on the display itself captures that display (Entire Screen).
  n0=$(nshots)
  tb_click "300 300"
  wait_shots $((n0 + 1))
  sleep 2
  fl_check "the toolbar is gone after Capture" test "$(tb_status | jq -r .open)" = false
  gref=$(ls -t "$pics"/*.png | head -2 | while read -r f; do [[ $(dims "$f") == 1920x1080 ]] && { echo "$f"; break; }; done)
  region=130x580+1780+40
  magick "$out/tb-icons-base.png" -crop $region +repage "$cs/.icons-live.png"
  magick "$gref" -crop $region +repage "$cs/.icons-file.png"
  d=$(vs_px_diff "$cs/.icons-live.png" "$cs/.icons-file.png")
  echo "icon column (130x580): pixels that differ between the saved picture and the desktop with its icons: $d"
  fl_check "Hide Desktop Icons: the saved picture has no icons (the icon column differs from the desktop by $d px, > 3000)" test "$d" -gt 3000
  cp "$gref" "$out/tb-hide-icons-file.png"
  icons_back() { shot tb-icons-after && magick "$out/tb-icons-after.png" -crop $region +repage "$cs/.icons-after.png" && [[ $(vs_px_diff "$cs/.icons-live.png" "$cs/.icons-after.png") -lt 300 ]]; }
  fl_check_wait "the icons are back once the picture is taken" 15 icons_back
  edit '.capture.hideDesktopIcons = false'
fi

if want freeze; then
  echo "== 4. the freeze channel (C4)"
  vs_ipc capture close >/dev/null
  cs_reset
  if ! wl1_ok; then
    echo "NOTE: NOT VERIFIED (freeze): grim of WAYLAND-1 does not return (the host does not repaint the nested window), so the helper's freeze, which grabs every display, cannot finish here."
  else
  quiet
  edit '.capture.thumbnailSeconds = 15'
  cs_timed "$out/fz-card.log" selection --geometry "1500,100 600x400"
  sleep 1.5
  fl_check "a card is up while the screen is frozen" test "$(card_count)" -ge 1
  shot fz-live
  freeze_start() { # freeze_start LOG ARGS...: the helper in the background; waits for the `frozen` state, sets TOKEN, FPATH, FPID
    local log=$1
    shift
    cs_helper selection --freeze "$@" > "$log" 2>&1 &
    FPID=$!
    vs_track "$FPID"
    TOKEN="" FPATH=""
    for _ in $(seq 1 60); do
      if [[ $(jq -r .phase "$state_dir/capture-state.json" 2>/dev/null) == frozen ]]; then
        TOKEN=$(jq -r .token "$state_dir/capture-state.json"); FPATH=$(jq -r '.frames[] | select(.output == "GF-REF") | .path' "$state_dir/capture-state.json"); return 0
      fi
      sleep 0.1
    done
    return 1
  }
  freeze_start "$out/fz1.log" --save screenshots
  fl_check "selection --freeze reaches the frozen state with a 128-bit token and a frame per display" test "${#TOKEN}" = 32 -a "$(jq -r '.frames | length' "$state_dir/capture-state.json")" -ge 2
  echo "frozen frames: $(jq -c '.frames' "$state_dir/capture-state.json")"
  # the frozen frame is the screen at 1920x1080 (device pixels), without the card
  # the folder is the dev state folder inside the helper's mount namespace
  fz=$state_dir/frozen/$(basename "$FPATH")
  magick "$fz" "$out/fz-frame.png"
  fl_check "the GF-REF frame is 1920x1080 device pixels ($(dims "$out/fz-frame.png"))" test "$(dims "$out/fz-frame.png")" = 1920x1080
  d=$(bbox "$out/fz-frame.png" "$out/fz-live.png" "700x600+1220+480")
  echo "difference between the frozen frame and the live screen (the card is only live): $d"
  fl_check "the frozen frame has no card, though the live screen has one" test -n "$d" -a "${d%% *}" != "0x0+0+0"
  # wrong token: refused, nothing written
  cs_helper choose --token 00000000000000000000000000000000 --geometry "1500,100 600x400" > "$out/fz-bad.log" 2>&1
  badrc=$?
  fl_check "choose with a wrong token is refused (exit $badrc, 2) and the freeze goes on" test "$badrc" = 2 -a ! -e "$state_dir/capture-choice.json" -a "$(jq -r .phase "$state_dir/capture-state.json")" = frozen
  cs_helper choose --token "$TOKEN" --geometry "1500,100 600x400" > "$out/fz-choose.log" 2>&1
  chrc=$?
  wait "$FPID"
  prim=$(result_field .primary)
  magick "$out/fz-frame.png" -crop 750x500+75+125 +repage "$out/fz-ref.png"
  echo "choose: rc=$chrc, file $(dims "$prim")"
  fl_check "choose crops the frozen frame: 750x500 at 1.25, pixel for pixel (differing pixels $(vs_px_diff "$prim" "$out/fz-ref.png"))" test "$chrc" = 0 -a "$(dims "$prim")" = 750x500 -a "$(vs_px_diff "$prim" "$out/fz-ref.png")" = 0
  fl_check "the frozen frames are removed after the picture" test ! -e "$state_dir/frozen" -o -z "$(ls -A "$state_dir/frozen" 2>/dev/null)"
  # a fractional rectangle is rounded outwards to whole device pixels
  freeze_start "$out/fz2.log" --save screenshots
  fz=$state_dir/frozen/$(basename "$FPATH")
  magick "$fz" "$out/fz-frame2.png"
  cs_helper choose --token "$TOKEN" --geometry "1501,101 601x401" > "$out/fz-choose2.log" 2>&1
  wait "$FPID"
  prim=$(result_field .primary)
  magick "$out/fz-frame2.png" -crop 752x502+76+126 +repage "$out/fz-ref2.png"
  fl_check "1501,101 601x401 (not a whole device pixel at 1.25) becomes 752x502 at 76,126 (outwards), exact: $(dims "$prim"), differing $(vs_px_diff "$prim" "$out/fz-ref2.png")" test "$(dims "$prim")" = 752x502 -a "$(vs_px_diff "$prim" "$out/fz-ref2.png")" = 0
  # a rectangle outside every frame is refused; Esc (cancel) captures nothing
  freeze_start "$out/fz3.log" --save screenshots
  cs_helper choose --token "$TOKEN" --geometry "1400,100 100x100" > "$out/fz-out.log" 2>&1
  outrc=$?
  fl_check "a rectangle across two displays' frames is refused (exit $outrc)" test "$outrc" = 2
  n0=$(nshots)
  cs_helper choose --token "$TOKEN" --cancel > "$out/fz-cancel.log" 2>&1
  wait "$FPID"
  fl_check "choose --cancel: nothing is captured, the frames are removed" test "$(nshots)" = "$n0" -a -z "$(ls -A "$state_dir/frozen" 2>/dev/null)"
  fi
  echo "NOTE: the frozen frame is not SHOWN on screen: the shell's freeze surface is slice A5, which is not in this tree (grep: no 'frozen' surface in shell/capture). NOT VERIFIED: the picture of the frozen screen under the pointer, and the loupe (A6)."
fi

if want editor; then
  echo "== 5. the Screenshot app (B1-B6, B8)"
  vs_ipc capture close >/dev/null
  cs_reset
  quiet
  bin=$VS_DEV/build/grassfield-screenshot
  [[ -x $bin ]] || { echo "FAIL: $bin missing (run apps/screenshot/build-direct.sh)"; fl_fail=1; }
  ed=$cs/editor
  rm -rf "$ed"; mkdir -p "$ed"
  # A fixture picture: a gradient under a checkerboard, so that any offset or resampling shows. 800x500 device pixels at scale 1.25.
  magick -size 800x500 gradient:'#2b6cb0'-'#f6ad55' -set Grassfield-Scale 1.25 \
    \( -size 800x500 pattern:checkerboard -alpha set -channel A -evaluate set 12% +channel \) -compose over -composite "$ed/in.png"
  cp "$ed/in.png" "$ed/work.png"
  ed_open() { # ed_open FILE: the editor on the nested compositor, its log in $ed/app.log
    "$VS_ROOT/scripts/dev/isolated.sh" --name visual --config-home "$VS_DEV/config" --state-home "$VS_DEV/state" -- \
      env WAYLAND_DISPLAY="$(vs_nested_wayland)" DBUS_SESSION_BUS_ADDRESS="$(<"$VS_DEV/bus.address")" LC_ALL=en_US.UTF-8 QSG_INFO=1 \
      QT_LOGGING_RULES="qt.scenegraph.general=true;qt.qpa.gl=true" QT_QPA_PLATFORM=wayland QT_NO_XDG_DESKTOP_PORTAL=1 \
      QML_IMPORT_PATH="$VS_ROOT/ui:$VS_DEV/build/qml" GRASSFIELD_TRANSLATIONS_DIR="$VS_DEV/translations" GRASSFIELD_LANG=en \
      HYPRLAND_INSTANCE_SIGNATURE="$(<"$VS_DEV/nested.instance")" "$bin" "$1" >"$ed/app.log" 2>&1 </dev/null &
    vs_track "$!"
    fl_wait 20 fl_has_window '^org\.grassfield\.Screenshot$'
    sleep 2
    vs_ipc notifications clearAll >/dev/null
    fl_focus_class '^org\.grassfield\.Screenshot$'
  }
  # ed_win: the editor window's "X Y W H" in device pixels, from the compositor's own client list (logical coordinates times the scale)
  ed_win() {
    local ox oy
    read -r ox oy <<<"$("$VS_ROOT/scripts/nestctl" monitors -j | jq -r --arg n "$VS_OUTPUT" '.[] | select(.name == $n) | "\(.x) \(.y)"')"
    "$VS_ROOT/scripts/nestctl" clients -j | jq -r --argjson s "$GRASSFIELD_REF_SCALE" --argjson ox "$ox" --argjson oy "$oy" \
      '[.[] | select(.mapped and .class == "org.grassfield.Screenshot")][0] | "\(((.at[0] - $ox) * $s) | round) \(((.at[1] - $oy) * $s) | round) \((.size[0] * $s) | round) \((.size[1] * $s) | round)"'
  }
  # canvas_box SHOT [TOP]: "WxH+X+Y" of the picture inside the window (the largest block that is not the window's own background), in device
  # pixels. Searched under the toolbar and the style bar of the window (ED_WIN), so no position is a constant of the layout.
  canvas_box() {
    local wx wy ww wh cx cy cw ch
    read -r wx wy ww wh <<<"$ED_WIN"
    cx=$((wx + 20)); cy=$((wy + ${2:-205})); cw=$((ww - 40)); ch=$((wh - ${2:-205} - 20))
    magick "$1" -crop "${cw}x${ch}+${cx}+${cy}" +repage -fuzz 10% -trim -format "%wx%h+%[fx:page.x+$cx]+%[fx:page.y+$cy]" info:
  }
  # ed_measure SHOT [TOP]: TOP is where the search starts below the window top (past the toolbar, and the style bar when it shows).
  # ed_measure SHOT: ED_WIN, ED_BOX and the picture's corner (ED_PX, ED_PY). The pointer is parked outside the window first.
  ed_measure() {
    vs_pointer abs 5 5 >/dev/null
    sleep 0.5
    ED_WIN=$(ed_win)
    shot "$1"
    ED_BOX=$(canvas_box "$out/$1.png" "${2:-205}")
    IFS='x+' read -r ED_W ED_H ED_PX ED_PY <<<"$ED_BOX"
    echo "$1: window $ED_WIN, picture box $ED_BOX"
  }
  # vs_pointer takes logical coordinates (the device pixels over the output scale).
  # ed_at DX DY: a point of the picture (in its own pixels) as a pointer position.
  ed_at() { awk -v x=$((ED_PX + $1)) -v y=$((ED_PY + $2)) -v s="$GRASSFIELD_REF_SCALE" 'BEGIN{printf "%.0f %.0f", x / s, y / s}'; }
  # ed_wat DX DY: a point of the window (device pixels from its top left corner, ED_WIN) as a pointer position.
  ed_wat() { local wx wy ww wh; read -r wx wy ww wh <<<"$ED_WIN"; awk -v x=$((wx + $1)) -v y=$((wy + $2)) -v s="$GRASSFIELD_REF_SCALE" 'BEGIN{printf "%.0f %.0f", x / s, y / s}'; }
  # edit_compare SHOT EXPORT: the exported PNG against the window's pixels over the picture (the export drawn at the view's size)
  ed_compare() {
    local box w h x y
    box=$ED_BOX
    IFS='x+' read -r w h x y <<<"$box"
    magick "$1" -crop "${w}x${h}+${x}+${y}" +repage "$cs/.view.png"
    magick "$2" -resize "${w}x${h}!" "$cs/.export.png"
    ED_BOX=$box
    ED_RMSE=$(magick compare -metric RMSE "$cs/.view.png" "$cs/.export.png" null: 2>&1 | sed 's/.*(\(.*\))/\1/')
  }
  ed_open "$ed/work.png"
  fl_check "the editor window opens" fl_has_window '^org\.grassfield\.Screenshot$'
  epid=$(pgrep -n -f "grassfield-screenshot $ed/work.png")
  gpulibs=$(grep -oE "lib(EGL|GLX|vulkan|gallium)[^ /]*|[a-z0-9_]+_dri\.so" "/proc/$epid/maps" 2>/dev/null | sort -u | tr '\n' ' ')
  echo "editor pid $epid maps: ${gpulibs:-none}; QT_QUICK_BACKEND=$(tr '\0' '\n' < /proc/$epid/environ 2>/dev/null | sed -n 's/^QT_QUICK_BACKEND=//p'); QSG_RHI_BACKEND=$(tr '\0' '\n' < /proc/$epid/environ 2>/dev/null | sed -n 's/^QSG_RHI_BACKEND=//p')"
  fl_check "the editor renders on the GPU (an EGL/Vulkan/GLX stack is loaded, no software backend requested: $gpulibs)" bash -c "[[ -n '$gpulibs' ]] && ! tr '\0' '\n' < /proc/$epid/environ | grep -qE '^QT_QUICK_BACKEND=software|^QSG_RHI_BACKEND=software'"
  # The picture before any tool: 100% must be 800x500 device pixels (the window's size and place come from the compositor, the box from this capture).
  ed_measure ed-open 70
  fl_check "100% shows the 800x500-pixel picture on 800x500 device pixels (box ${ED_BOX}; at 1.25 it should not be magnified)" test "${ED_BOX%%+*}" = 800x500
  tool() { fl_key "$1"; sleep 0.3; }
  # Every tool but Select shows the style bar, which moves the picture down: measured again, then every click is the picture's corner plus an offset.
  tool a
  ed_measure ed-tool
  read -r WX WY WW WH <<<"$ED_WIN"
  vs_pointer abs $(ed_at 40 25) sleep 200 down sleep 100 drag $(ed_at 260 115) sleep 100 up >/dev/null
  tool r
  vs_pointer abs $(ed_at 320 5) sleep 200 down sleep 100 drag $(ed_at 480 105) sleep 100 up >/dev/null
  tool o
  vs_pointer abs $(ed_at 100 85) sleep 200 down sleep 100 drag $(ed_at 200 165) sleep 100 up >/dev/null
  tool l
  vs_pointer abs $(ed_at 320 145) sleep 200 down sleep 100 drag $(ed_at 520 245) sleep 100 up >/dev/null
  tool p
  vs_pointer abs $(ed_at 40 215) sleep 200 down sleep 100 drag $(ed_at 120 255) drag $(ed_at 180 195) drag $(ed_at 260 265) sleep 100 up >/dev/null
  tool h
  vs_pointer abs $(ed_at 320 185) sleep 200 down sleep 100 drag $(ed_at 520 185) sleep 100 up >/dev/null
  tool n
  vs_pointer abs $(ed_at 570 35) sleep 200 click >/dev/null
  vs_pointer abs $(ed_at 620 35) sleep 200 click >/dev/null
  vs_pointer abs $(ed_at 670 35) sleep 200 click >/dev/null
  # text in the three styles (Plain, Outlined, Pill: the style bar)
  tool t
  ed_measure ed-text
  # the style bar's Outlined and Pill buttons, in device pixels from the window's top left corner (read off ed-text.png: the bar is at +90)
  TXT_OUTLINED=517 TXT_PILL=600
  vs_pointer abs $(ed_at 40 305) sleep 200 click >/dev/null; sleep 0.4; fl_type "Plain 1.25"; fl_tap Return; fl_tap Escape
  vs_pointer abs $(ed_wat $TXT_OUTLINED 90) sleep 200 click >/dev/null
  vs_pointer abs $(ed_at 40 365) sleep 200 click >/dev/null; sleep 0.4; fl_type "Outlined"; fl_tap Return; fl_tap Escape
  vs_pointer abs $(ed_wat $TXT_PILL 90) sleep 200 click >/dev/null
  vs_pointer abs $(ed_at 40 425) sleep 200 click >/dev/null; sleep 0.4; fl_type "Pill"; fl_tap Return; fl_tap Escape
  tool v
  sleep 1
  ed_measure ed-final 70
  ed_compare "$out/ed-final.png" "$ed/in.png"
  fl_check "the annotated picture is still 800x500 device pixels (box ${ED_BOX})" test "${ED_BOX%%+*}" = 800x500
  echo "canvas box ${ED_BOX}; view against the UNANNOTATED picture: RMSE $ED_RMSE"
  ctrl=$ED_RMSE
  fl_appkey ctrl s
  sleep 2
  fl_check "Done (Ctrl+S) writes a PNG of the same size ($(dims "$ed/work.png"))" test "$(dims "$ed/work.png")" = 800x500
  cp "$ed/work.png" "$out/ed-export.png"
  ed_compare "$out/ed-final.png" "$ed/work.png"
  echo "canvas box ${ED_BOX}; view against the EXPORT: RMSE $ED_RMSE (against the unannotated picture $ctrl)"
  fl_check "screen = export: the window's picture matches the exported PNG (RMSE $ED_RMSE < 0.04, and far under the unannotated $ctrl)" awk -v a="$ED_RMSE" -v c="$ctrl" 'BEGIN{exit !(a < 0.04 && a * 2 < c)}'
  sleep 1
  fl_check "Done closed the editor window" bash -c "! '$VS_ROOT/scripts/nestctl' clients -j | jq -e 'any(.[]; .mapped and .class == \"org.grassfield.Screenshot\")' >/dev/null"
  # round 2: crop (a handle dragged in), rotate right, exact against ImageMagick's own crop and rotation of the same pixels
  cp "$ed/in.png" "$ed/work2.png"
  ed_open "$ed/work2.png"
  tool c
  sleep 0.6
  ed_measure ed-crop
  vs_pointer abs $(ed_at 6 6) sleep 200 down sleep 150 drag $(ed_at 66 46) sleep 150 up >/dev/null
  sleep 0.8
  shot ed-crop2
  fl_tap Return
  sleep 0.8
  tool v
  fl_appkey ctrl r
  sleep 0.8
  shot ed-rotated
  fl_appkey ctrl s
  sleep 2
  echo "rotated export: $(dims "$ed/work2.png")"
  eh=$(magick identify -format '%h' "$ed/work2.png"); ew=$(magick identify -format '%w' "$ed/work2.png")
  # the crop kept the bottom right corner: eh x ew before the turn
  magick "$ed/in.png" -crop "${eh}x${ew}+$((800 - eh))+$((500 - ew))" +repage -rotate 90 -depth 8 "$ed/ref2.png"
  fl_check "crop then rotate right is pixel exact (export ${ew}x${eh} from 800x500; differing pixels against ImageMagick: $(magick compare -metric AE "$ed/work2.png" "$ed/ref2.png" null: 2>&1))" test "$(magick compare -metric AE "$ed/work2.png" "$ed/ref2.png" null: 2>&1 | cut -d' ' -f1)" = 0
  fl_check "the crop took something off (export is smaller than 500x800)" test "$ew" -lt 500 -o "$eh" -lt 800
fi

if want multi; then
  echo "== 6. Capture Entire Screen on every display, the Capture button's way (no --output)"
  vs_ipc capture close >/dev/null
  cs_reset
  if ! wl1_ok; then
    echo "NOTE: NOT VERIFIED (every-display capture): grim of WAYLAND-1 does not return here (see freeze)."
  else
  quiet
  edit '.capture.thumbnailSeconds = 15'
  vs_ipc notifications clearAll >/dev/null 2>&1
  rm -f "$state_dir/capture-result.json"
  cs_helper screen > "$out/multi.log" 2>&1 &
  vs_track "$!"
  seq_ph=""
  for _ in $(seq 1 16); do
    sleep 0.5
    seq_ph="$seq_ph $(jq -r .phase "$state_dir/capture-state.json")"
  done
  echo "state phases every 0.5 s for 8 s:$seq_ph"
  echo "state: $(cat "$state_dir/capture-state.json")"
  echo "result: $(jq -c '[.kind,.output]' "$state_dir/capture-result.json" 2>/dev/null); cards $(card_count); banners $(fl_notif banners)"
  # grim of the nested window's own output (WAYLAND-1), bounded (docs/testing: it waits for the host to repaint that window)
  timeout 15 "$VS_ROOT/scripts/dev/shot.sh" cs-multi-w1 WAYLAND-1 >/dev/null 2>&1
  echo "grim of WAYLAND-1: exit $? (124 = waited for the host window to repaint)"
  fl_check "the every-display capture is finished within 5 s (phase at 5 s: $(echo "$seq_ph" | cut -d' ' -f11))" test "$(echo "$seq_ph" | cut -d' ' -f11)" = idle
  fl_check "a card shows for the picture of GF-REF" test "$(card_count)" -ge 1
  cs_reset
  fi
fi

fl_done
