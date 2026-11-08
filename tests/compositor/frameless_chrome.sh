#!/usr/bin/env bash
# L1 nested scenario: every window has its controls, and only one set (rc7 audit R7-REQ-01 / R7-UX-01, owner 2026-11-08: a
# frameless window that draws nothing and has no title bar is a defect; plugin work item P9, docs/specs/compositor.md; ADR-0015
# amendment 2026-11-08). Qt negotiates the same for every frameless window (the xdg-decoration manager bound, no decoration
# object), so the plugin tells a window that draws its own title bar by its frame: a window geometry inside its surface (the
# shadow margins Telegram's lib_ui sets through QtWayland). Firefox left the per-app list: its negotiation tells its own frame
# (KDE client) from its "Title Bar" option (KDE server, Hyprland draws nothing).
#
# Usage: tests/compositor/frameless_chrome.sh
# NESTED only, bare: needs scripts/dev/nested-up.sh with the plugin loaded. Clients start through scripts/dev/isolated.sh on
# the nested socket; hyprctl only through scripts/nestctl (read-only, plus window moves, raises and Hyprland's maximize).
#   F1 a Qt frameless window that draws nothing (tests/compositor/frameless-fixture/frameless.cpp): no client-chrome tag
#   F2 a Qt frameless window that draws its own title bar and shadow, with QtWayland's custom margins (Telegram's way): the tag
#   F3 F2 maximized by Hyprland's own dispatcher (it drops its shadow and margins, as lib_ui does): still tagged; and back
#   F4 Firefox's own frame (a GTK 3 window of app id firefox whose title bar is client-side, Firefox's gtk_window_set_titlebar
#      with an empty widget: KDE server-decoration client): the tag
#   F5 Firefox with its "Title Bar" option on (a plain GTK 3 window of app id firefox: KDE server): no tag
#   F6 a capture (each window raised): the plugin's strip above F1 and F5, none above F2 and F4 (the row 4 px under the strip's
#      top and 4 px above the window, at 20-80 % of its width, against the strip's colours, as decorations.sh D9 measures)
# Exit: 0 PASS, 1 FAIL, 2 usage or environment error. Log: .dev/frameless-chrome/run-<timestamp>.log.
set -uo pipefail

root=$(git -C "$(dirname "$0")" rev-parse --show-toplevel)
dev=$root/.dev
out=${FRAMELESS_OUTPUT:-GF-REF}
# shellcheck source=../../scripts/dev/pidfile.sh
. "$root/scripts/dev/pidfile.sh"
# shellcheck source=titlebar_geometry.sh
. "$root/tests/compositor/titlebar_geometry.sh" || exit 2
dev_nested_target "$dev" || exit 2
sock=$DEV_NESTED_SOCK sig=$DEV_NESTED_SIG hypr_pid=$DEV_NESTED_PID
main=$(cat "$dev/main.instance" 2>/dev/null || true)
if [[ $sig == "$main" || $sig == "${HYPRLAND_INSTANCE_SIGNATURE:-}" || $sock == "${WAYLAND_DISPLAY:-}" ]]; then
  echo "frameless_chrome: refusing: recorded nested instance is the main session" >&2
  exit 2
fi
bus=$(cat "$dev/bus.address" 2>/dev/null || echo disabled:)

work=$dev/frameless-chrome
mkdir -p "$work" "$dev/tools"
log=$work/run-$(date +%Y%m%d-%H%M%S).log
say() { printf '%s %s\n' "$(date '+%H:%M:%S')" "$*" | tee -a "$log"; }
ctl() { timeout 10 "$root/scripts/nestctl" "$@"; }
pointer() { timeout 30 "$root/scripts/dev/pointer.sh" output "$out" "$@" >>"$log" 2>&1; }

ctl -j plugin list 2>/dev/null | jq -e '[.[]? | select(.name == "grassfield-compositor")] | length > 0' >/dev/null ||
  { echo "frameless_chrome: the plugin is not loaded" >&2; exit 2; }
read -r mon_x mon_y mon_scale < <(ctl monitors -j | jq -r --arg o "$out" '.[] | select(.name == $o) | "\(.x) \(.y) \(.scale)"')
[[ -n ${mon_x:-} ]] || { echo "frameless_chrome: output $out not found" >&2; exit 2; }

# The fixture: Qt 6 Gui and its private headers (QNativeInterface::Private::QWaylandWindow, as lib_ui uses it).
src=$root/tests/compositor/frameless-fixture/frameless.cpp
bin=$dev/tools/gf-frameless
qtver=$(pkg-config --modversion Qt6Gui 2>/dev/null || true)
[[ -n $qtver ]] || { echo "frameless_chrome: Qt6Gui not found by pkg-config" >&2; exit 2; }
if [[ ! -x $bin || $src -nt $bin ]]; then
  qtinc=$(pkg-config --variable=includedir Qt6Gui)
  # shellcheck disable=SC2046
  g++ -std=c++17 -O1 -fPIC -Wall -Wextra "$src" -I"$qtinc/QtGui/$qtver" -I"$qtinc/QtGui/$qtver/QtGui" -I"$qtinc/QtCore/$qtver" \
    -I"$qtinc/QtCore/$qtver/QtCore" $(pkg-config --cflags --libs Qt6Gui) -o "$bin" >>"$log" 2>&1 ||
    { say "setup error: the frameless fixture did not build (see $log)"; exit 2; }
fi
python3 -c 'import gi; gi.require_version("Gtk", "3.0")' 2>/dev/null || { echo "frameless_chrome: python GTK 3 not available" >&2; exit 2; }
command -v magick >/dev/null && command -v grim >/dev/null || { echo "frameless_chrome: magick and grim are needed for F6" >&2; exit 2; }

pids=()
cleanup() {
  local p
  for p in "${pids[@]}"; do pkill -P "$p" 2>/dev/null; kill "$p" 2>/dev/null; done
}
trap cleanup EXIT

fail=0
check() { if [[ $2 == 0 ]]; then say "  $1: OK   ($3)"; else say "  $1: FAIL ($3)"; fail=1; fi; }
# "<address> <tags joined by ,>" of the window titled $1.
window_of() { ctl clients -j | jq -r --arg t "$1" '[.[] | select(.title == $t)][0] | select(. != null) | "\(.address) \(.tags | join(","))"'; }
wait_window() { local i; for i in $(seq 1 80); do [[ -n $(window_of "$1") ]] && return 0; sleep 0.25; done; return 1; }
has_tag() { # <title>: the client-chrome tag (the plugin's static one, or a rule's dynamic one with "*")
  local t
  for t in $(window_of "$1" | cut -d' ' -f2 | tr ',' ' '); do
    [[ $t == grassfield-client-chrome || $t == 'grassfield-client-chrome*' ]] && return 0
  done
  return 1
}
run_client() { # <name> <command...>: on the nested socket, isolated
  local name=$1
  shift
  env -u DISPLAY WAYLAND_DISPLAY="$sock" DBUS_SESSION_BUS_ADDRESS="$bus" GDK_BACKEND=wayland QT_QPA_PLATFORM=wayland \
    setsid "$root/scripts/dev/isolated.sh" --name "frameless-$name" -- "$@" >>"$log" 2>&1 </dev/null &
  pids+=($!)
}
expect_tag() { # <title> <0|1> <case> <what>
  local t=$1 want=$2 got=0
  if ! wait_window "$t"; then check "$3 $4" 1 "the window '$t' did not map"; return; fi
  sleep 0.8 # the tag follows the client's first commits (its margins come with the commit after its first buffer)
  has_tag "$t" && got=1
  check "$3 $4" "$([[ $got == "$want" ]] && echo 0 || echo 1)" "tags '$(window_of "$t" | cut -d' ' -f2)', want the tag: $want"
}
strip_above() { # <png> <x> <y> <w> (logical px relative to the output): 1 when both rows have the strip's colour
  local i r hexes=() px py
  for r in 4 $((GF_TB_HEIGHT - 4)); do
    for i in 20 35 50 65 80; do
      px=$(awk -v x="$2" -v w="$4" -v i="$i" -v s="$mon_scale" 'BEGIN { printf "%d", (x + w * i / 100) * s }')
      py=$(awk -v y="$3" -v r="$r" -v s="$mon_scale" 'BEGIN { printf "%d", (y - r) * s }')
      hexes+=("$(magick "$1" -format "%[hex:p{$px,$py}]" info: 2>/dev/null | cut -c1-6)")
    done
  done
  python3 -I - "$(jq -r '.titlebar.backgroundDark.value' "$root/ui/tokens/tokens.json")" \
    "$(jq -r '.titlebar.backgroundLight.value' "$root/ui/tokens/tokens.json")" "${hexes[@]}" <<'PY'
import sys
def rgb(h):
    h = h.lstrip("#")
    return tuple(int(h[i:i + 2], 16) for i in (0, 2, 4)) if len(h) >= 6 else None
tokens = [rgb(t) for t in sys.argv[1:3]]
points = [rgb(h) for h in sys.argv[3:]]
def near(a, b):
    return a is not None and b is not None and max(abs(x - y) for x, y in zip(a, b)) <= 8
print(1 if points and all(any(near(p, t) for t in tokens) for p in points) else 0)
PY
}
place_raise() { # <title> <x> <y> (logical, relative to the output)
  local a
  a=$(window_of "$1" | cut -d' ' -f1)
  ctl dispatch "hl.dsp.window.move({ x = $((mon_x + $2)), y = $((mon_y + $3)), window = 'address:$a' })" >>"$log" 2>&1
  ctl dispatch "hl.dsp.window.alter_zorder({ mode = 'top', window = 'address:$a' })" >>"$log" 2>&1
}
geom_rel() { ctl clients -j | jq -r --arg t "$1" --argjson mx "$mon_x" --argjson my "$mon_y" '[.[] | select(.title == $t)][0] | select(. != null) | "\(.at[0] - $mx) \(.at[1] - $my) \(.size[0])"'; }
fullscreen_of() { ctl clients -j | jq -r --arg t "$1" '[.[] | select(.title == $t)][0].fullscreen // empty'; }

say "frameless_chrome: nested pid $hypr_pid, instance $sig, output $out (scale $mon_scale), Qt $qtver"
pointer abs 400 400 sleep 100 # new windows open on $out

run_client qt-bare "$bin" gf-frameless-bare
expect_tag gf-frameless-bare 0 F1 "a Qt frameless window that draws nothing keeps the plugin's titlebar"
run_client qt-own "$bin" --own-bar 16 gf-frameless-own
expect_tag gf-frameless-own 1 F2 "a Qt frameless window that draws its own title bar and shadow (Telegram's custom margins): the plugin steps aside"

# F3: maximized by Hyprland's own dispatcher, the window drops its shadow and margins (a commit of a new size and geometry):
# its title bar is still its own.
own=$(window_of gf-frameless-own | cut -d' ' -f1)
if [[ -n $own ]]; then
  ctl dispatch "hl.dsp.window.fullscreen({ mode = \"maximized\", window = \"address:$own\" })" >>"$log" 2>&1
  sleep 1
  zoomed=$(fullscreen_of gf-frameless-own)
  has_tag gf-frameless-own
  check "F3 maximized (no shadow, no margins): still the client's own title bar" $? "fullscreen state '${zoomed:-?}', tags '$(window_of gf-frameless-own | cut -d' ' -f2)'"
  ctl dispatch "hl.dsp.window.fullscreen({ mode = \"maximized\", window = \"address:$own\" })" >>"$log" 2>&1
  sleep 1
  has_tag gf-frameless-own
  check "F3 back from maximized: still tagged" $? "fullscreen state '$(fullscreen_of gf-frameless-own)', tags '$(window_of gf-frameless-own | cut -d' ' -f2)'"
else
  check "F3 maximized" 1 "no window gf-frameless-own"
fi

gtk=$root/tests/compositor/frameless-fixture/gtk-window.py
run_client firefox-csd python3 -I "$gtk" firefox gf-frameless-firefox-own 1
expect_tag gf-frameless-firefox-own 1 F4 "Firefox's own frame (KDE client): the plugin steps aside"
run_client firefox-titlebar python3 -I "$gtk" firefox gf-frameless-firefox-titlebar 0
expect_tag gf-frameless-firefox-titlebar 0 F5 "Firefox with its Title Bar option (KDE server, no bar drawn): the plugin's titlebar"

# F6: the strip, measured on a capture with the windows apart and raised. The invariant: one bar per window.
place_raise gf-frameless-bare 40 80
place_raise gf-frameless-own 700 80
place_raise gf-frameless-firefox-titlebar 40 500
place_raise gf-frameless-firefox-own 700 500
sleep 0.8
WAYLAND_DISPLAY=$sock timeout 10 grim -o "$out" "$work/strip.png" 2>>"$log"
verdict=0 detail=""
for spec in gf-frameless-bare:1 gf-frameless-own:0 gf-frameless-firefox-titlebar:1 gf-frameless-firefox-own:0; do
  t=${spec%:*} want=${spec#*:}
  read -r gx gy gw < <(geom_rel "$t")
  got=$(strip_above "$work/strip.png" "${gx:-0}" "${gy:-0}" "${gw:-0}")
  # The tags at the capture: a strip with the tag is a drawing fault, a strip without it the decision (integrator, 2026-11-08).
  detail+="$t $got (want $want, tags '$(window_of "$t" | cut -d' ' -f2)'); "
  [[ $got == "$want" ]] || verdict=1
done
check "F6 one title bar each: the plugin's strip above the frameless window that draws nothing and above Firefox's Title Bar mode, none above the two that draw their own" "$verdict" "${detail}capture $work/strip.png"

say "frameless_chrome: plugin log: $(ctl rollinglog 2>/dev/null | grep -a 'negotiated' | tail -n 8 | sed 's/.*\[grassfield\] //' | tr '\n' ';')"
say "frameless_chrome: $([[ $fail == 0 ]] && echo PASS || echo FAIL)"
exit "$fail"
