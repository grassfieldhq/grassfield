#!/usr/bin/env bash
# Nested scenario, gate L4 (lock privacy) plus DT-05 (screen-share protection) and the D-4 lid lock and display
# power-off. Never targets the owner's session; never types anything (no key reaches the lock field, so PAM is never
# involved). The nested session stays LOCKED afterwards (only the owner's password opens it): finish with
# scripts/dev/nested-down.sh.
#
# Usage: tests/security/lock_privacy.sh [step...]   (default: every step, in this order)
#   setup        marker image; on GF-REF, side by side, three foot windows: "gf-privacy-probe" filled with the marker
#                colour (magenta), "gf-privacy-twin" filled with green (unprotected) and "Bitwarden" (protected) with
#                the twin's foot options and size; three notifications whose image is the marker. Fixture self-check
#                before the Bitwarden window opens: a capture must show the probe's magenta and the twin's green. The
#                test's only capture path, grim over Hyprland's capture protocols, honours no_screen_share (that is
#                what DT-05 checks), so the twin is how the test knows that green renders at all. Without that proof
#                every "0 marker px" and "0 green px" check below FAILS instead of passing. Then the banners must show
#                the marker outside the probe window, or the lock screen's "0 marker px" FAILS as well.
#   screenshare  DT-05 / SEC-01: in a capture of the unlocked desktop the probe is magenta and the twin green (controls),
#                the Bitwarden window's region is black and its box holds no green pixel (Omarchy's no_screen_share
#                rule, config/hypr/grassfield/privacy.lua)
#   control      the probe and twin windows' own regions are magenta and green before locking (not the banners, which
#                expire): the detectors work
#   lock         `lock lid` (D-4: the nested outputs WAYLAND-1 and GF-REF are not external displays, so the lid locks)
#   privacy      L4: while locked, two more notifications (one critical), and every surface IPC can open (Search, Apps,
#                Notification Center, menu bar menu, Overview, Dock menu); the capture of GF-REF (probe, twin, banners)
#                holds no marker and no green pixel (the twin is unprotected window content), WAYLAND-1 shows neither
#                when it gives a frame; Hyprland reports LOCK on every monitor
#   display-off  D-4: with `idle devDisplayOff 4` set before the lock, the shell turns the displays off after 4 s
#                without input (idle status displayOff, Hyprland dpmsStatus) and on again on pointer motion; dark again,
#                then `idle devSleep after` (the after-resume path) lights them without input, still locked, and they go
#                dark again 4 s later; a `devSleep before` right after a resume keeps them dark; the next resume lights them
#   auto-sleep   automatic sleep: energy.preventSleep false in the dev config and `idle devAutoSleep 2`: 2 s after the
#                displays went off on the lock screen one sleep comes due and the dev session suppresses it (counted, never
#                run), the 5-minute retry armed; with it true none comes due (battery or power adapter); locked
#                throughout. Leaves energy.preventSleep true
#   cleanup      close the foot windows (the session stays locked)
# The fixture steps read GF-REF only (headless: it always draws). privacy also reads WAYLAND-1, the nested window on the
# owner's screen, which gives grim a frame only while the owner's compositor draws it: without one it is reported
# NOT VERIFIED (it carries no fixture; its lock is covered by LOCK on every monitor). Every wait is bounded
# (timeout(1), counted loops); nothing waits forever.
# Requires scripts/dev/nested-up.sh (GRASSFIELD_DEV=1 shell on a private bus: notify-send reaches only it). Can start right
# after it: before any step, waits at most READY_SECONDS (default 60) for GF-REF and a lock state from the shell
# (tests/security/nested_ready.sh); a timeout FAILs (exit 1) and runs no step. With `setup` among the steps, a shell
# that runs without GRASSFIELD_DESKTOP_SCREEN=GF-REF is restarted once with `scripts/dev/shell-run.sh --desktop-screen
# GF-REF`: the banners, the Dock and the icons follow the main display (ADR-0044), and this test reads GF-REF.
# Exit status: 0 when every requested step passed; NOT VERIFIED items are counted on the last line and leave it unchanged.
set -uo pipefail

root=$(git -C "$(dirname "$0")" rev-parse --show-toplevel)
# GRASSFIELD_MIGRATED=1: the nested session runs the packaged form of the UI tree (scripts/dev/shell-run.sh --migrated,
# ADR-0056): both instances are addressed by their path under .dev/migrated.
ui_dir=$root/shell; sec_qml=$root/shell/security.qml
[[ ${GRASSFIELD_MIGRATED:-0} == 1 ]] && { ui_dir=$root/.dev/migrated/shell; sec_qml=$ui_dir/security.qml; }
dev=$root/.dev
# shellcheck source=../../scripts/dev/pidfile.sh
. "$root/scripts/dev/pidfile.sh"
dev_require_host lock_privacy
dev_nested_target "$dev" || exit 2
sig=$DEV_NESTED_SIG
sock=$DEV_NESTED_SOCK
bus=$(cat "$dev/bus.address" 2>/dev/null || true)
[[ $bus == unix:path=/tmp/dbus-* ]] || { echo "lock_privacy: no private bus of the nested shell (.dev/bus.address); run scripts/dev/nested-up.sh" >&2; exit 2; }
# Testing rule after the review of 423766f (a probe once reached the owner's session bus): only the nested shell's
# private bus, never the caller's own, and notify-send runs under `env -i` with that address alone.
[[ $bus != *"/run/user/"* && ( -z ${DBUS_SESSION_BUS_ADDRESS:-} || $bus != "$DBUS_SESSION_BUS_ADDRESS" ) ]] || { echo "lock_privacy: refusing the caller's own session bus ($bus)" >&2; exit 2; }
for tool in grim magick notify-send foot jq awk timeout; do
  command -v "$tool" >/dev/null || { echo "lock_privacy: $tool is not installed" >&2; exit 2; }
done
# shellcheck source=nested_ready.sh
. "$root/tests/security/nested_ready.sh"

work=$dev/lock-privacy
mkdir -p "$work"
marker=$work/marker.png
fixture=$work/fixture # key=value lines written by setup: probe, protected (window addresses), proven=1 (self-check)
out=GF-REF            # the output the fixture windows open on, and the one the region checks cut from
win_w=560 win_h=360   # fixture window size (logical px)
inset=16              # a region check skips this border of a window (rounded corners, rims)
status=0
why="" # reason of the last helper failure
nested() { env WAYLAND_DISPLAY="$sock" HYPRLAND_INSTANCE_SIGNATURE="$sig" "$@"; }
# Every call that waits on another process is bounded (timeout(1)); its caller FAILs naming what it waited for. A
# nested output the host does not draw never sends grim a frame (an integrator run hung 25 min on WAYLAND-1, the nested
# window on the owner's screen), a stuck shell never answers IPC, a busy notification server never replies.
hypr() { nested timeout -k 2 5 hyprctl "$@" 2>/dev/null; }
# The lock and idle targets are on the security instance since ADR-0041 step 1, S2 (shell/security.qml, started beside the
# shell by scripts/dev/shell-run.sh); every other target on the shell.
ipc() {
  local where="$ui_dir"
  case $1 in lock | idle | security) where="$sec_qml" ;; esac
  nested timeout -k 2 5 qs ipc -p "$where" call "$@" 2>/dev/null
}
pointer() { timeout -k 2 20 "$root/scripts/dev/pointer.sh" output "$@" >/dev/null 2>&1; }
pass() { echo "PASS $*"; }
fail() { echo "FAIL $*"; status=1; }
# Something this run could not observe and that no check depends on: reported and counted, the exit status unchanged.
not_verified=0
notverified() { echo "NOT VERIFIED $*"; not_verified=$((not_verified + 1)); }
notify() { env -i PATH="$PATH" DBUS_SESSION_BUS_ADDRESS="$bus" timeout -k 2 5 notify-send "$@" >/dev/null 2>&1; }

compositor_locked() {
  hypr -j monitors | jq -e 'length > 0 and all(.[]; (.solitaryBlockedBy // []) | index("LOCK") != null)' >/dev/null
}

wait_status() { # <expected> <seconds>
  local want=$1 tries=$(($2 * 4)) got=""
  for _ in $(seq 1 "$tries"); do
    got=$(ipc lock status)
    [[ $got == "$want" ]] && { echo "$got"; return 0; }
    sleep 0.25
  done
  echo "${got:-no-answer}"
  return 1
}

# Pixels of <colour> (8 % fuzz) in a PNG.
count_colour() { # <png> <#rrggbb>
  magick "$1" -alpha off -fuzz 8% -fill black +opaque "$2" -fill white -opaque "$2" -format '%[fx:round(mean*w*h)]' info: 2>/dev/null || echo error
}

# Fraction (0..1) of the pixels of a PNG within 8 % of <colour>, black included: the matches are first painted a
# sentinel colour, then the sentinel becomes white and everything else black. True colour first: a cut that is all
# black or all grey is stored as a greyscale PNG, where the sentinel would turn grey and match nothing.
colour_frac() { # <png> <#rrggbb>
  magick "$1" -alpha off -colorspace sRGB -type TrueColor -fuzz 8% -fill "#010203" -opaque "$2" -fuzz 0 \
    -fill black +opaque "#010203" -fill white -opaque "#010203" -format '%[fx:mean]' info: 2>/dev/null || echo error
}

at_least() { # <fraction> <minimum>: false for anything that is not a number
  [[ $1 =~ ^[0-9]+(\.[0-9]+)?(e[-+]?[0-9]+)?$ ]] && awk -v a="$1" -v b="$2" 'BEGIN { exit !(a + 0 >= b + 0) }'
}

near() { # <a> <b> <a0> <b0>: four integers, a within 2 of a0 and b within 2 of b0 (a position or a size)
  local v
  for v in "$@"; do [[ $v =~ ^-?[0-9]+$ ]] || return 1; done
  (($1 - $3 <= 2 && $3 - $1 <= 2 && $2 - $4 <= 2 && $4 - $2 <= 2))
}

# Grabs one output to <png>, never leaving an older file in its place: the captures stay in $work between runs and
# the fixture windows open at the same places every run, so a stale image would pass every check. The file is deleted
# first and must exist, be non-empty and be no older than the grab's start. grim waits for the output's next frame:
# GF-REF (headless) draws on its own, WAYLAND-1 only when the owner's compositor draws the nested window (seen at 27 s),
# so each grab has a deadline. Sets grab_why on failure (also printed on stderr).
grab_why=""
grab() { # <output> <png>
  local start t rc limit=10 hint="the nested compositor drew no frame"
  [[ $1 == WAYLAND-1 ]] && limit=30 hint="is the nested window shown on the owner's screen?"
  grab_why=""
  start=$(date +%s)
  rm -f "$2"
  nested timeout -k 2 "$limit" grim -o "$1" "$2" 2>/dev/null
  rc=$?
  if ((rc == 124 || rc == 137)); then # 137: killed after the 2 s grace (-k)
    grab_why="grim -o $1 got no frame within $limit s ($hint)"
  elif ((rc != 0)); then
    grab_why="grim -o $1 failed (exit $rc)"
  elif ! { t=$(stat -c %Y "$2" 2>/dev/null) && [[ -s $2 && $t =~ ^[0-9]+$ ]] && ((t >= start)); }; then
    grab_why="grim -o $1 left no fresh $2"
  fi
  [[ -z $grab_why ]] || { echo "lock_privacy: $grab_why" >&2; return 1; }
}

# Captures nested outputs (default $out, the fixture's) to $work/<name>-<output>.png: prints "<magenta> <green>"
# summed, or "error error <reason>" when a grab or a count fails (the callers then FAIL with the reason).
capture() { # <name> [<output>...]
  local name=$1 output png m=0 g=0 c
  shift
  [[ $# -gt 0 ]] || set -- "$out"
  for output in "$@"; do
    png=$work/$name-$output.png
    grab "$output" "$png" 2>/dev/null || { echo "error error $grab_why"; return; }
    c=$(count_colour "$png" "#ff00ff"); [[ $c =~ ^[0-9]+$ ]] || { echo "error error cannot count colours in $png"; return; }
    m=$((m + c))
    c=$(count_colour "$png" "#00ff00"); [[ $c =~ ^[0-9]+$ ]] || { echo "error error cannot count colours in $png"; return; }
    g=$((g + c))
  done
  echo "$m $g"
}

mon_x="" mon_y="" mon_w="" mon_h="" mon_scale=""
monitor_load() { # position and logical size of $out (layout px) and its scale; sets why on failure
  read -r mon_x mon_y mon_w mon_h mon_scale < <(hypr -j monitors | jq -r --arg o "$out" \
    '.[] | select(.name == $o) | "\(.x) \(.y) \(.width / .scale | floor) \(.height / .scale | floor) \(.scale)"')
  [[ ${mon_w:-} =~ ^[0-9]+$ && ${mon_h:-} =~ ^[0-9]+$ ]] || { why="Hyprland lists no monitor $out"; return 1; }
}

client_info() { # <address> -> "<x> <y> <w> <h> <class> <pid>" (layout px); nothing when that window is gone
  [[ -n $1 ]] || return 0
  hypr -j clients | jq -r --arg a "$1" \
    '.[] | select(.address == $a) | "\(.at[0]) \(.at[1]) \(.size[0]) \(.size[1]) \(.class) \(.pid)"' | head -n 1
}

class_present() { # <class>
  hypr -j clients | jq -e --arg c "$1" 'any(.[]; .class == $c)' >/dev/null
}

fixture_get() { # <key>: the last value setup wrote
  [[ -s $fixture ]] && sed -n "s/^$1=//p" "$fixture" | tail -n 1
}

# The fixture record was written by a setup in this nested instance (it stays in $work between runs and sessions).
fixture_ours() {
  [[ $(fixture_get instance) == "$sig" ]] || { why="no setup ran in this nested session (setup step)"; return 1; }
}

# Succeeds when the setup's self-check passed in this session and its probe, twin and Bitwarden windows are still
# open; sets why otherwise.
fixture_proven() {
  fixture_ours || return 1
  [[ $(fixture_get proven) == 1 ]] || { why="the fixture self-check did not pass (setup step)"; return 1; }
  [[ $(client_info "$(fixture_get probe)") == *" gf-privacy-probe "* ]] || { why="the self-checked probe window is gone"; return 1; }
  [[ $(client_info "$(fixture_get twin)") == *" gf-privacy-twin "* ]] || { why="the self-checked green twin window is gone"; return 1; }
  [[ $(client_info "$(fixture_get protected)") == *" Bitwarden "* ]] || { why="the self-checked Bitwarden window is gone"; return 1; }
}

# The inner part of a window (its box minus <inset>, default $inset, on each side) cut from a capture of $out to
# $work/<name>.png and measured for <colour>: prints "<fraction> <colour at its centre>", or "error none" (window
# gone, cut failed).
region() { # <capture png> <window address> <name> <#rrggbb> [<inset>]
  local x y w h png=$work/$3.png geometry centre i=${5:-$inset}
  read -r x y w h _ < <(client_info "$2")
  rm -f "$png"
  [[ ${h:-} =~ ^[0-9]+$ ]] && ((w > 2 * i && h > 2 * i)) || { echo "error none"; return; }
  geometry=$(awk -v x="$x" -v y="$y" -v w="$w" -v h="$h" -v mx="$mon_x" -v my="$mon_y" -v s="$mon_scale" -v i="$i" \
    'BEGIN { printf "%dx%d+%d+%d", (w - 2 * i) * s, (h - 2 * i) * s, (x - mx + i) * s, (y - my + i) * s }')
  magick "$1" -crop "$geometry" +repage "$png" 2>/dev/null || { echo "error none"; return; }
  centre=$(magick "$png" -alpha off -gravity center -crop 1x1+0+0 +repage -format '#%[hex:p{0,0}]' info: 2>/dev/null) || centre=none
  echo "$(colour_frac "$png" "$4") ${centre:-none}"
}

# Waits for windows to show their colours: grabs $out until each <address> <colour> pair covers at least 0.9 of the
# window's region, at most 6 times (new windows and moves animate). Cheap (region cuts only); the checks that decide
# run on a capture taken afterwards.
settle() { # <name> <address> <#rrggbb> [<address> <#rrggbb>...]
  local name=$1 png f k ok
  shift
  local -a pairs=("$@")
  png=$work/$name-settle-$out.png
  for _ in $(seq 1 6); do
    ok=0
    if grab "$out" "$png" 2>/dev/null; then
      ok=1
      for ((k = 0; k + 1 < ${#pairs[@]}; k += 2)); do
        read -r f _ < <(region "$png" "${pairs[k]}" "$name-settle" "${pairs[k + 1]}")
        at_least "$f" 0.9 || { ok=0; break; }
      done
    fi
    ((ok)) && return 0
    sleep 0.5
  done
  return 1
}

# Pixels of <colour> in a capture of $out outside a window's box (the box, grown by 8 px, is painted black first).
# Alpha goes off after the paint: -draw turns an alpha channel back on, and the mean would then count it.
count_outside() { # <png> <address> <#rrggbb>
  local x y w h box
  read -r x y w h _ < <(client_info "$2")
  [[ ${h:-} =~ ^[0-9]+$ ]] || { echo error; return; }
  box=$(awk -v x="$x" -v y="$y" -v w="$w" -v h="$h" -v mx="$mon_x" -v my="$mon_y" -v s="$mon_scale" \
    'BEGIN { printf "rectangle %d,%d %d,%d", (x - mx - 8) * s, (y - my - 8) * s, (x - mx + w + 8) * s, (y - my + h + 8) * s }')
  magick "$1" -fill black -draw "$box" -alpha off -fuzz 8% -fill black +opaque "$3" -fill white -opaque "$3" \
    -format '%[fx:round(mean*w*h)]' info: 2>/dev/null || echo error
}

# True when the two windows' boxes, each with the 48 px band above it (titlebar, shadow), share no pixel.
apart() { # <address> <address>
  local ax ay aw ah bx by bw bh
  read -r ax ay aw ah _ < <(client_info "$1")
  read -r bx by bw bh _ < <(client_info "$2")
  [[ ${ah:-} =~ ^[0-9]+$ && ${bh:-} =~ ^[0-9]+$ ]] || return 1
  ! ((ax < bx + bw && bx < ax + aw && ay - 48 < by + bh && by - 48 < ay + ah))
}

# foot's colour options. foot 1.28 (installed 2026-10-16) reads [colors-dark] and [colors-light] only: an override of
# the older [colors] section is a config error that foot reports and then ignores, so the window opens in its default
# colours (black). Both themes get the same colour (whichever foot starts in), alpha 1 (no wallpaper through). An older
# foot that knows only [colors] gets that spelling. Each set is checked with `foot --check-config` (exit 230 on any
# config error, no window) before a window opens.
foot_style=""
foot_check() { # <foot options...>: prints foot's config errors and fails when foot rejects them
  env -u WAYLAND_DISPLAY timeout -k 2 10 "$root/scripts/dev/isolated.sh" foot --check-config "$@" 2>&1 >/dev/null
}
colour_opts() { # <rrggbb>: sets the array opts
  case $foot_style in
    dark-light) opts=(-o "colors-dark.background=$1" -o "colors-dark.foreground=$1" -o colors-dark.alpha=1
      -o "colors-light.background=$1" -o "colors-light.foreground=$1" -o colors-light.alpha=1) ;;
    legacy) opts=(-o "colors.background=$1" -o "colors.foreground=$1" -o colors.alpha=1) ;;
    *) opts=() ;;
  esac
}
detect_foot_style() {
  if foot_check -o colors-dark.background=000000 -o colors-light.background=000000 >/dev/null; then
    foot_style=dark-light
  elif foot_check -o colors.background=000000 >/dev/null; then
    foot_style=legacy
  else
    return 1
  fi
}

# Opens a ${win_w}x${win_h} foot window filled with <rrggbb> (no text, no cursor) and moves it to <x>,<y> of $out
# (logical px). Sets win_addr; sets why on failure. Windows open centred under the pointer, so without the move the
# second fixture window would cover the first.
win_addr=""
foot_window() { # <app id> <rrggbb> <x> <y>
  local opts err pid addr="" cpid="" x="" y="" tx=$((mon_x + $3)) ty=$((mon_y + $4))
  win_addr=""
  [[ -n $foot_style ]] || detect_foot_style || { why="foot accepts neither [colors-dark] nor [colors] colour overrides"; return 1; }
  colour_opts "$2"
  err=$(foot_check "${opts[@]}") || { why="foot rejects the colour options ${opts[*]}: $err"; return 1; }
  class_present "$1" && { why="a $1 window is already open (an earlier run?): restart the nested session (nested-down, nested-up)"; return 1; }
  # Not through nested(): a shell function sent to the background runs in a subshell, and $! would name that subshell
  # (stopping it leaves foot open). Here $! is foot itself, the leader of its own session (setsid).
  env WAYLAND_DISPLAY="$sock" HYPRLAND_INSTANCE_SIGNATURE="$sig" setsid "$root/scripts/dev/isolated.sh" foot --app-id="$1" \
    --window-size-pixels="${win_w}x${win_h}" "${opts[@]}" -- sh -c 'printf "\033[?25l"; exec sleep 3600' >/dev/null 2>&1 </dev/null &
  pid=$!
  dev_record_pid "$dev/privacy-$1.pid" "$pid"
  for _ in $(seq 1 40); do
    addr=$(hypr -j clients | jq -r --arg c "$1" '[.[] | select(.class == $c)] | first | .address // empty')
    [[ -n $addr ]] && break
    sleep 0.25
  done
  [[ -n $addr ]] || { why="no $1 window appeared"; return 1; }
  # The record must name the process that owns the window: the window's own pid when it is another foot.
  read -r _ _ _ _ _ cpid < <(client_info "$addr")
  [[ ${cpid:-} =~ ^[0-9]+$ && $cpid != "$pid" && $(cat "/proc/$cpid/comm" 2>/dev/null) == foot ]] && dev_record_pid "$dev/privacy-$1.pid" "$cpid"
  timeout -k 2 5 "$root/scripts/nestctl" dispatch "hl.dsp.window.move({ x = $tx, y = $ty, window = 'address:$addr' })" >/dev/null 2>&1
  for _ in $(seq 1 20); do
    read -r x y _ < <(client_info "$addr")
    near "$x" "$y" "$tx" "$ty" && break
    sleep 0.15
  done
  near "$x" "$y" "$tx" "$ty" \
    || { why="the $1 window did not move to ($3,$4) of $out (it is at ${x:-?},${y:-?} in layout px, target $tx,$ty)"; return 1; }
  win_addr=$addr
}

step_setup() {
  local gap y x0 x1 x2 probe twin protected i m="" g="" cerr="" pm="error" pc="none" gm="error" gc="none" ok=1 bx by bw bh tw th
  rm -f "$fixture"
  echo "instance=$sig" >>"$fixture"
  magick -size 64x64 xc:"#ff00ff" "$marker" || { fail "setup: cannot draw the marker image"; return; }
  monitor_load || { fail "setup: $why"; return; }
  # Three columns: probe, twin, Bitwarden.
  gap=$(((mon_w - 3 * win_w) / 4)) y=$(((mon_h - win_h) / 2))
  x0=$gap x1=$((2 * gap + win_w)) x2=$((3 * gap + 2 * win_w))
  ((gap >= 32 && mon_h >= win_h + 200)) \
    || { fail "setup: $out (${mon_w}x${mon_h}) has no room for three ${win_w}x${win_h} windows side by side"; return; }
  # New windows open on the output under the pointer; it rests on bare desktop below the row (not on the Dock).
  pointer "$out" abs $((mon_w / 2)) $((y + win_h + 80)) >/dev/null
  foot_window gf-privacy-probe ff00ff "$x0" "$y" || { fail "setup: marker window: $why"; return; }
  probe=$win_addr
  echo "probe=$probe" >>"$fixture"
  pass "setup: marker window (gf-privacy-probe) at ($x0,$y) of $out"
  foot_window gf-privacy-twin 00ff00 "$x1" "$y" || { fail "setup: twin window: $why"; return; }
  twin=$win_addr
  echo "twin=$twin" >>"$fixture"
  apart "$probe" "$twin" || { fail "setup: the probe and twin windows overlap: $(client_info "$probe") / $(client_info "$twin")"; return; }

  # Self-check: each fixture colour renders, read in the windows' own regions (not the banners).
  settle selfcheck "$probe" "#ff00ff" "$twin" "#00ff00" || true
  read -r m g cerr < <(capture selfcheck)
  [[ $m =~ ^[0-9]+$ && $g =~ ^[0-9]+$ ]] || { fail "setup: self-check: the capture failed ($cerr), nothing is proven"; return; }
  read -r pm pc < <(region "$work/selfcheck-$out.png" "$probe" selfcheck-probe "#ff00ff")
  read -r gm gc < <(region "$work/selfcheck-$out.png" "$twin" selfcheck-twin "#00ff00")
  echo "self-check capture: probe region magenta $pm (centre $pc), twin region green $gm (centre $gc); whole $out: magenta $m px, green $g px ($work/selfcheck-$out.png)"
  at_least "$pm" 0.9 || { fail "setup: self-check: the probe window is not magenta ($pm of its region, centre $pc): every marker check would prove nothing"; ok=0; }
  at_least "$gm" 0.9 || { fail "setup: self-check: the unprotected twin is not green ($gm of its region, centre $gc): every green check would pass vacuously"; ok=0; }
  ((ok)) || return
  pass "setup: self-check: the probe window renders magenta ($pm of its region), an unprotected green window renders green ($gm)"

  # The Bitwarden window: the twin's foot options and size, only the app id differs. The twin stays open through the
  # lock: it is the unprotected window content the "0 green px" check on the lock screen is about.
  foot_window Bitwarden 00ff00 "$x2" "$y" || { fail "setup: protected window: $why"; return; }
  protected=$win_addr
  read -r bx by bw bh _ < <(client_info "$protected")
  read -r _ _ tw th _ < <(client_info "$twin")
  near "${bw:-}" "${bh:-}" "${tw:-}" "${th:-}" \
    || { fail "setup: the Bitwarden window (${bw:-?}x${bh:-?}) is not the twin's size (${tw:-?}x${th:-?})"; return; }
  apart "$probe" "$protected" && apart "$twin" "$protected" \
    || { fail "setup: the Bitwarden window overlaps the probe or the twin: $(client_info "$protected")"; return; }
  echo "protected=$protected" >>"$fixture"
  echo "proven=1" >>"$fixture"
  pass "setup: protected window (app id Bitwarden) at ($((bx - mon_x)),$((by - mon_y))) of $out, ${bw}x${bh}, the twin's size (${tw}x${th})"

  for i in 1 2 3; do
    notify -i "$marker" -h "string:image-path:$marker" "L4 privacy $i" "token-$RANDOM$RANDOM"
  done
  sleep 1
  echo "notifications: $(ipc notifications status)"
  # The notification image renders before the lock: magenta outside the probe window can only be the banners' marker,
  # so "0 marker px" on the lock screen covers notification images too (each banner shows it at about 32x32 px). The
  # banners show on the main display (ADR-0044), which this run pins to $out (GRASSFIELD_DESKTOP_SCREEN, before the
  # steps); WAYLAND-1 is not read here (see grab).
  local bm=""
  for i in $(seq 1 6); do
    if grab "$out" "$work/banners-$out.png" 2>/dev/null; then
      bm=$(count_outside "$work/banners-$out.png" "$probe" "#ff00ff")
    else
      bm="error ($grab_why)"
    fi
    [[ $bm =~ ^[0-9]+$ ]] && ((bm >= 500)) && break
    sleep 0.5
  done
  echo "banners capture: marker px outside the probe window: $bm ($work/banners-$out.png)"
  if [[ $bm =~ ^[0-9]+$ ]] && ((bm >= 500)); then
    echo "banners=1" >>"$fixture"
    pass "setup: the notification banners show the marker image before the lock ($bm px outside the probe window)"
  else
    fail "setup: the notification banners never showed the marker image ($bm px outside the probe window; banner surface on '$(banners_output)', shell main display override '$(shell_env GRASSFIELD_DESKTOP_SCREEN)'): 0 marker px on the lock screen would not cover notification images"
  fi
}

# The output that holds the shell's banner surface (layer namespace grassfield-banners, shell/notifications/Banners.qml), ""
# when there is none: says where the banners went when the setup does not see them on $out.
banners_output() {
  hypr -j layers | jq -r 'to_entries[] | select(any(.value.levels[]?[]?; .namespace == "grassfield-banners")) | .key' 2>/dev/null | head -n 1
}

# The value of <variable> in the live nested shell's environment (empty when unset, or with no live shell record).
shell_env() { # <variable>
  local pid
  pid=$(dev_live_pid "$dev/shell.pid") || return 0
  tr '\0' '\n' <"/proc/$pid/environ" 2>/dev/null | sed -n "s/^$1=//p" | head -n 1
}

step_screenshare() {
  local m="" g="" cerr="" pm pc gm gc bk bc bg probe twin protected
  fixture_proven || { fail "screenshare: $why: the screen-share checks would prove nothing"; return; }
  monitor_load || { fail "screenshare: $why"; return; }
  probe=$(fixture_get probe) twin=$(fixture_get twin) protected=$(fixture_get protected)
  settle screenshare "$probe" "#ff00ff" "$twin" "#00ff00" "$protected" "#000000" || true
  read -r m g cerr < <(capture screenshare)
  [[ $m =~ ^[0-9]+$ && $g =~ ^[0-9]+$ ]] || { fail "screenshare: the capture failed ($cerr)"; return; }
  read -r pm pc < <(region "$work/screenshare-$out.png" "$probe" screenshare-probe "#ff00ff")
  read -r gm gc < <(region "$work/screenshare-$out.png" "$twin" screenshare-twin "#00ff00")
  read -r bk bc < <(region "$work/screenshare-$out.png" "$protected" screenshare-bitwarden "#000000")
  # Green anywhere in the Bitwarden window's whole box (no inset): its own pixels leaking.
  read -r _ _ < <(region "$work/screenshare-$out.png" "$protected" screenshare-bitwarden-box "#00ff00" 0)
  bg=$(count_colour "$work/screenshare-bitwarden-box.png" "#00ff00")
  echo "screenshare capture: probe region magenta $pm (centre $pc), twin region green $gm (centre $gc), Bitwarden region black $bk (centre $bc), green px in the Bitwarden box $bg; whole $out: magenta $m px, green $g px ($work/screenshare-$out.png)"
  at_least "$pm" 0.9 && pass "screenshare: the unprotected probe window is captured (control: $pm of its region magenta)" \
    || fail "screenshare: the probe window is not captured ($pm of its region magenta, centre $pc)"
  at_least "$gm" 0.9 && pass "screenshare: the unprotected green twin is captured green (control: $gm of its region)" \
    || fail "screenshare: the green twin is not captured green ($gm of its region, centre $gc): the green check would prove nothing"
  at_least "$bk" 0.9 && pass "screenshare: the Bitwarden window is black in the capture ($bk of its region)" \
    || fail "screenshare: the Bitwarden window's region is not black ($bk, centre $bc) (SEC-01)"
  [[ $bg == 0 ]] && pass "screenshare: no green pixel of the Bitwarden window is captured (the green twin is, in the same frame)" \
    || fail "screenshare: ${bg} green px of the Bitwarden window were captured (SEC-01)"
}

step_control() {
  local m="" g="" cerr="" pm pc gm gc probe twin
  monitor_load || { fail "control: $why"; return; }
  fixture_ours || { fail "control: $why"; return; }
  probe=$(fixture_get probe) twin=$(fixture_get twin)
  [[ $(client_info "$probe") == *" gf-privacy-probe "* ]] || { fail "control: no probe window (run the setup step first)"; return; }
  [[ $(client_info "$twin") == *" gf-privacy-twin "* ]] || { fail "control: no green twin window (run the setup step first)"; return; }
  settle control "$probe" "#ff00ff" "$twin" "#00ff00" || true
  read -r m g cerr < <(capture control)
  [[ $m =~ ^[0-9]+$ && $g =~ ^[0-9]+$ ]] || { fail "control: the capture failed ($cerr)"; return; }
  read -r pm pc < <(region "$work/control-$out.png" "$probe" control-probe "#ff00ff")
  read -r gm gc < <(region "$work/control-$out.png" "$twin" control-twin "#00ff00")
  echo "control capture: probe region magenta $pm (centre $pc), twin region green $gm (centre $gc); whole $out, banners included: magenta $m px, green $g px ($work/control-$out.png)"
  at_least "$pm" 0.9 && pass "control: the probe window shows the marker colour before the lock ($pm of its region): the detector works" \
    || fail "control: the probe window is not magenta before the lock ($pm of its region, centre $pc): the privacy check would prove nothing"
  at_least "$gm" 0.9 && pass "control: the unprotected green twin shows green before the lock ($gm of its region)" \
    || fail "control: the green twin is not green before the lock ($gm of its region, centre $gc): the green check would prove nothing"
}

step_lock() {
  local answer s
  echo "idle devDisplayOff 4 -> $(ipc idle devDisplayOff 4)"
  answer=$(ipc lock lid)
  echo "lock lid -> $answer"
  [[ $answer == ok ]] && pass "lock: the lid locks with no external display (nested outputs)" || fail "lock: lock lid answered '$answer'"
  if s=$(wait_status locked 10); then pass "lock: status $s"; else fail "lock: status $s"; fi
  for _ in $(seq 1 40); do compositor_locked && break; sleep 0.1; done
  compositor_locked && pass "lock: Hyprland reports LOCK on every monitor" || fail "lock: Hyprland does not report LOCK"
}

step_privacy() {
  local m g cerr output proven=1
  fixture_proven || proven=0
  notify -i "$marker" -h "string:image-path:$marker" "L4 privacy while locked" "token-$RANDOM"
  notify -u critical -i "$marker" -h "string:image-path:$marker" "L4 privacy critical" "token-$RANDOM"
  # Every surface IPC can open (dev hooks and actions alike): none may show over the lock.
  ipc search open privacy >/dev/null
  ipc apps open >/dev/null
  ipc notifications toggleCenter >/dev/null
  ipc menubar open system "" >/dev/null
  ipc overview open >/dev/null
  ipc dock menu 0 "" >/dev/null
  sleep 1.5
  # GF-REF carries the probe, the twin and the banners: fully fail-closed. WAYLAND-1 carries none of them, so its 0 px
  # proves nothing: any marker or green pixel on it FAILs, no frame is NOT VERIFIED (exit status unchanged), and its
  # lock is covered by "LOCK on every monitor" below.
  for output in GF-REF WAYLAND-1; do
    read -r m g cerr < <(capture privacy "$output")
    if [[ ! $m =~ ^[0-9]+$ || ! $g =~ ^[0-9]+$ ]]; then
      if [[ $output == "$out" ]]; then
        fail "privacy: $output not checked: $cerr"
      else
        notverified "privacy: $output lock screen not captured: $cerr"
      fi
      continue
    fi
    echo "privacy capture $output: magenta $m, green $g ($work/privacy-$output.png)"
    if [[ $output != "$out" ]]; then
      if ((m != 0 || g != 0)); then
        fail "privacy: $output: $m marker px and $g green px on the lock screen (notification or window content visible, L4)"
      else
        echo "INFO privacy: $output: 0 marker px, 0 green px (it carries no fixture, so this proves nothing more)"
      fi
      continue
    fi
    if ((m != 0)); then
      fail "privacy: $output: $m marker pixels on the lock screen (notification or window content visible, L4)"
    elif ((!proven)); then
      fail "privacy: $output: 0 marker px proves nothing: $why"
    elif [[ $(fixture_get banners) != 1 ]]; then
      fail "privacy: $output: 0 marker px does not cover notification images: the banners never showed the marker before the lock (setup step)"
    else
      pass "privacy: $output: no notification image, banner or window content on the lock screen (0 marker px; the banners and the probe showed it before the lock)"
    fi
    if ((g != 0)); then
      fail "privacy: $output: $g green px on the lock screen (the unprotected twin's content is visible, L4)"
    elif ((proven)); then
      pass "privacy: $output: no window content, the unprotected green twin is hidden (0 green px)"
    else
      fail "privacy: $output: 0 green px proves nothing: $why"
    fi
  done
  compositor_locked && pass "privacy: still locked (LOCK on every monitor)" || fail "privacy: Hyprland no longer reports LOCK"
}

dpms_all() { # <true|false>: every monitor's dpmsStatus
  hypr -j monitors | jq -e --argjson v "$1" 'length > 0 and all(.[]; .dpmsStatus == $v)' >/dev/null
}

step_display_off() {
  local st off=""
  for _ in $(seq 1 40); do
    st=$(ipc idle status)
    [[ $(jq -r '.displayOff' <<<"$st" 2>/dev/null) == true ]] && { off=1; break; }
    sleep 0.25
  done
  [[ -n $off ]] && pass "display-off: displays turned off after 4 s without input on the lock screen" || fail "display-off: idle status $st"
  dpms_all false && pass "display-off: Hyprland reports every display off (dpmsStatus false)" || echo "display-off: dpmsStatus $(hypr -j monitors | jq -c '[.[] | {name, dpmsStatus}]') (informational on nested outputs)"
  pointer GF-REF abs 800 500 sleep 100 abs 820 520 >/dev/null
  off=""
  for _ in $(seq 1 20); do
    st=$(ipc idle status)
    [[ $(jq -r '.displayOff' <<<"$st" 2>/dev/null) == false ]] && { off=1; break; }
    sleep 0.25
  done
  [[ -n $off ]] && pass "display-off: pointer motion turns the displays on again" || fail "display-off: still off after input: $st"
  dpms_all true && pass "display-off: Hyprland reports every display on" || fail "display-off: dpmsStatus $(hypr -j monitors | jq -c '[.[] | {name, dpmsStatus}]')"
  compositor_locked && pass "display-off: still locked" || fail "display-off: Hyprland no longer reports LOCK"
  # A resume from sleep lights the lock screen (Idle.wakeAfterResume, the owner's rc6 report): dark again without input, then
  # the after-resume path (`idle devSleep after`, no logind in the dev session) turns the displays on within
  # IdleModel.RESUME_WAKE_MS (1.5 s) without any input; the session stays locked.
  off=""
  for _ in $(seq 1 40); do
    st=$(ipc idle status)
    [[ $(jq -r '.displayOff' <<<"$st" 2>/dev/null) == true ]] && { off=1; break; }
    sleep 0.25
  done
  [[ -n $off ]] && pass "display-off: dark again after 4 s without input" || fail "display-off: not dark again: $st"
  echo "idle devSleep after -> $(ipc idle devSleep after)"
  off=""
  for _ in $(seq 1 16); do
    st=$(ipc idle status)
    [[ $(jq -r '.displayOff' <<<"$st" 2>/dev/null) == false ]] && { off=1; break; }
    sleep 0.25
  done
  [[ -n $off ]] && pass "display-off: a resume lights the lock screen without input" || fail "display-off: still off after the resume: $st"
  compositor_locked && pass "display-off: still locked after the resume" || fail "display-off: Hyprland no longer reports LOCK after the resume"
  # ...and the lock screen's countdown runs again from the resume: dark again after its 4 s without input (review of c94e3195:
  # without Idle.armAfterResume the monitor stayed disarmed, the displays lit for the rest of the session). Within 8 s.
  off=""
  for _ in $(seq 1 32); do
    st=$(ipc idle status)
    [[ $(jq -r '.displayOff' <<<"$st" 2>/dev/null) == true ]] && { off=1; break; }
    sleep 0.25
  done
  [[ -n $off ]] && pass "display-off: dark again without input after the resume" || fail "display-off: still lit 8 s after the resume: $st"
  # A sleep that starts before the wake is due (review of c94e3195): a resume, then at once the before-sleep path: the displays
  # stay dark past IdleModel.RESUME_WAKE_MS; the next resume lights them.
  echo "idle devSleep after -> $(ipc idle devSleep after); idle devSleep before -> $(ipc idle devSleep before)"
  sleep 2.5
  st=$(ipc idle status)
  [[ $(jq -r '.displayOff' <<<"$st" 2>/dev/null) == true ]] && pass "display-off: a sleep that starts before the wake keeps the displays dark" \
    || fail "display-off: lit by the previous resume although a sleep had started: $st"
  echo "idle devSleep after -> $(ipc idle devSleep after)"
  off=""
  for _ in $(seq 1 16); do
    st=$(ipc idle status)
    [[ $(jq -r '.displayOff' <<<"$st" 2>/dev/null) == false ]] && { off=1; break; }
    sleep 0.25
  done
  [[ -n $off ]] && pass "display-off: the next resume lights them" || fail "display-off: still off after the next resume: $st"
  compositor_locked && pass "display-off: still locked at the end" || fail "display-off: Hyprland no longer reports LOCK at the end"
}

# The dev config this nested shell reads (GRASSFIELD_CONFIG_HOME=.dev/config, scripts/dev/shell-run.sh): energy.preventSleep
# set to $1 (true/false), the rest of the file kept; the shell follows it live.
set_prevent_sleep() {
  local cfg=$dev/config/grassfield.json tmp
  mkdir -p "$dev/config"
  tmp=$(mktemp "$dev/config/.grassfield.json.XXXXXX")
  if [[ -s $cfg ]]; then
    jq --argjson v "$1" '.energy = ((.energy // {}) + {preventSleep: $v})' "$cfg" >"$tmp" || { rm -f "$tmp"; return 1; }
  else
    jq -n --argjson v "$1" '{version: 1, energy: {preventSleep: $v}}' >"$tmp" || { rm -f "$tmp"; return 1; }
  fi
  mv -f "$tmp" "$cfg"
}

idle_field() { jq -r "$1" <<<"$(ipc idle status)" 2>/dev/null; }

# Waits until the lock screen's monitor has the displays off again (input first lights them).
displays_off_again() {
  local _
  pointer GF-REF abs 760 460 sleep 100 abs 780 480 >/dev/null
  for _ in $(seq 1 40); do
    [[ $(idle_field '.displayOff') == false ]] && break
    sleep 0.25
  done
  for _ in $(seq 1 60); do
    [[ $(idle_field '.displayOff') == true ]] && return 0
    sleep 0.25
  done
  return 1
}

# Automatic sleep (2026-11-04, Settings > Energy / Battery > Options…): locked with the displays off for 2 s without input
# (`idle devAutoSleep 2`), a computer whose sleep is not prevented would suspend; the dev session never does: it counts the
# due suspend (`autoSleepSuppressed`) instead, and the retry timer (5 min) is armed. With energy.preventSleep on, nothing is
# due, on battery as on the power adapter (integrator decision 2026-11-04). The session stays locked either way.
step_auto_sleep() {
  local before after
  echo "idle devAutoSleep 2 -> $(ipc idle devAutoSleep 2)"
  set_prevent_sleep false || { fail "auto-sleep: the dev config could not be written"; return; }
  for _ in $(seq 1 20); do [[ $(idle_field '.sleepPrevented') == false ]] && break; sleep 0.25; done
  [[ $(idle_field '.sleepPrevented') == false ]] && pass "auto-sleep: energy.preventSleep false reaches the idle module (sleepPrevented false)" \
    || fail "auto-sleep: sleepPrevented $(idle_field '.sleepPrevented') after writing false"
  before=$(idle_field '.autoSleepSuppressed')
  displays_off_again && pass "auto-sleep: the lock screen turned the displays off again" || fail "auto-sleep: the displays did not go off ($(ipc idle status))"
  for _ in $(seq 1 40); do
    after=$(idle_field '.autoSleepSuppressed')
    [[ $after =~ ^[0-9]+$ && $before =~ ^[0-9]+$ ]] && ((after > before)) && break
    sleep 0.25
  done
  [[ $after =~ ^[0-9]+$ && $before =~ ^[0-9]+$ ]] && ((after == before + 1)) \
    && pass "auto-sleep: one automatic sleep came due 2 s after the displays went off, and the dev session suppressed it ($before -> $after)" \
    || fail "auto-sleep: autoSleepSuppressed $before -> $after ($(ipc idle status))"
  [[ $(idle_field '.autoSleepRetrying') == true ]] && pass "auto-sleep: the retry timer is armed while the displays stay off" \
    || fail "auto-sleep: no retry armed ($(ipc idle status))"
  sleep 3
  [[ $(idle_field '.autoSleepSuppressed') == "$after" ]] && pass "auto-sleep: no second request within the retry interval (5 min): no tight loop" \
    || fail "auto-sleep: requested again without input ($(idle_field '.autoSleepSuppressed'))"
  compositor_locked && pass "auto-sleep: still locked (LOCK on every monitor)" || fail "auto-sleep: Hyprland no longer reports LOCK"
  set_prevent_sleep true || { fail "auto-sleep: the dev config could not be written"; return; }
  for _ in $(seq 1 20); do [[ $(idle_field '.sleepPrevented') == true ]] && break; sleep 0.25; done
  [[ $(idle_field '.sleepPrevented') == true ]] && pass "auto-sleep: energy.preventSleep true reaches the idle module, whatever the power source" \
    || fail "auto-sleep: sleepPrevented $(idle_field '.sleepPrevented') after writing true"
  before=$(idle_field '.autoSleepSuppressed')
  displays_off_again || fail "auto-sleep: the displays did not go off with prevent-sleep on ($(ipc idle status))"
  sleep 4
  after=$(idle_field '.autoSleepSuppressed')
  [[ $after == "$before" && $(idle_field '.autoSleepArmed') == false && $(idle_field '.autoSleepRetrying') == false ]] \
    && pass "auto-sleep: prevent-sleep on: the displays are off, the session locked, and no sleep comes due" \
    || fail "auto-sleep: prevent-sleep on, yet autoSleepSuppressed $before -> $after ($(ipc idle status))"
  [[ $(idle_field '.displayOff') == true ]] && pass "auto-sleep: prevent-sleep keeps the displays' own power-off" \
    || fail "auto-sleep: displays not off with prevent-sleep on"
  compositor_locked && pass "auto-sleep: still locked with prevent-sleep on" || fail "auto-sleep: Hyprland no longer reports LOCK"
  echo "idle devAutoSleep 60 -> $(ipc idle devAutoSleep 60)"
}

step_cleanup() {
  local id
  for id in gf-privacy-probe gf-privacy-twin Bitwarden; do
    dev_stop "$dev/privacy-$id.pid" "privacy $id foot" >/dev/null || true
  done
  rm -f "$fixture"
  echo "captures kept in $work; the nested session stays locked (scripts/dev/nested-down.sh)"
}

steps=("$@")
[[ ${#steps[@]} -gt 0 ]] || steps=(setup screenshare control lock privacy display-off auto-sleep cleanup)
# Ready first (tests/security/nested_ready.sh): GF-REF listed and a lock state from the shell. Right after nested-up the
# shell does not answer yet, and its empty answer is no lock state (it once stopped this run as "already locked"). A
# timeout FAILs: no step runs on an unknown state. Only `cleanup` needs no shell.
needs_shell=0
for s in "${steps[@]}"; do [[ $s == cleanup ]] || needs_shell=1; done
if ((needs_shell)); then
  ready_rc=0
  nested_ready "$sig" "$sock" "$sec_qml" "${READY_SECONDS:-60}" || ready_rc=$?
  case $ready_rc in
    0) echo "ready: GF-REF listed, lock status $nested_ready_state, after $nested_ready_ms ms" ;;
    2) echo "lock_privacy: $nested_ready_why" >&2; exit 2 ;;
    *) echo "FAIL ready: $nested_ready_why"; echo "lock_privacy: no step ran; exit status 1"; exit 1 ;;
  esac
  [[ $nested_ready_state == unlocked || " ${steps[*]} " != *" lock "* ]] \
    || { echo "lock_privacy: the nested session is already $nested_ready_state; restart it (nested-down, nested-up) for the default run" >&2; exit 2; }
fi
# The banners, the Dock and the desktop icons show on the main display (ADR-0044, shell/services/MainDisplay.qml; before it
# the banners followed the pointer's output, where this test parks it). With WAYLAND-1 and GF-REF that is the first output,
# a race, unless the dev override GRASSFIELD_DESKTOP_SCREEN names one: the integrator's run of 2026-11-04 on d03fea8c had the
# banners on WAYLAND-1 and both banner checks failed on GF-REF. This test looks at GF-REF only (the fixture, the banners,
# the surfaces it opens while locked), so the shell must run with GRASSFIELD_DESKTOP_SCREEN=GF-REF, as the visual suite's
# shell does (tests/visual/lib.sh). A shell started without it (`scripts/dev/nested-up.sh` alone, as `just
# test-security-nested` does) is restarted once with `scripts/dev/shell-run.sh --desktop-screen GF-REF` before the setup
# (unlocked: the default run refuses a locked session above); the product rule is unchanged. Without `setup` in the steps
# nothing is restarted (the banners of an earlier setup would go): a note says so.
if [[ " ${steps[*]} " == *" setup "* ]]; then
  if [[ $(shell_env GRASSFIELD_DESKTOP_SCREEN) != "$out" ]]; then
    echo "main display: the nested shell runs without GRASSFIELD_DESKTOP_SCREEN=$out (banners on '$(banners_output)'); restarting it with --desktop-screen $out"
    "$root/scripts/dev/shell-run.sh" --desktop-screen "$out" >/dev/null || { echo "FAIL ready: scripts/dev/shell-run.sh --desktop-screen $out failed"; exit 1; }
    ready_rc=0
    nested_ready "$sig" "$sock" "$sec_qml" "${READY_SECONDS:-60}" || ready_rc=$?
    ((ready_rc == 0)) || { echo "FAIL ready: after the restart with --desktop-screen $out: $nested_ready_why"; exit 1; }
    # The lock is the security process's (ADR-0041 S2), which the UI's restart leaves alone: wait for the UI itself too, until
    # it answers a dev query of its own (its configuration has loaded).
    ui_up=0
    for _ in $(seq 1 $((${READY_SECONDS:-60} * 4))); do
      [[ -n $(ipc overview status) ]] && { ui_up=1; break; }
      sleep 0.25
    done
    ((ui_up)) || { echo "FAIL ready: the restarted shell did not answer \`overview status\` within ${READY_SECONDS:-60} s"; exit 1; }
    [[ $nested_ready_state == unlocked || " ${steps[*]} " != *" lock "* ]] \
      || { echo "FAIL ready: the restarted shell is $nested_ready_state, not unlocked"; exit 1; }
    [[ $(shell_env GRASSFIELD_DESKTOP_SCREEN) == "$out" ]] \
      || { echo "FAIL ready: the restarted shell still runs without GRASSFIELD_DESKTOP_SCREEN=$out"; exit 1; }
    echo "ready: the shell restarted with its main display on $out, lock status $nested_ready_state, after $nested_ready_ms ms"
  fi
elif [[ $(shell_env GRASSFIELD_DESKTOP_SCREEN) != "$out" ]]; then
  echo "NOTE the nested shell runs without GRASSFIELD_DESKTOP_SCREEN=$out: its banners and Dock may be on another output than the one these steps read"
fi
for s in "${steps[@]}"; do
  echo "== $s"
  declare -F "step_${s//-/_}" >/dev/null || { echo "lock_privacy: unknown step $s" >&2; exit 2; }
  "step_${s//-/_}"
done
echo "lock_privacy: $not_verified NOT VERIFIED item(s); exit status $status"
exit $status
