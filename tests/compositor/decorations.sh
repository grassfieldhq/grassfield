#!/usr/bin/env bash
# L1 nested scenario: one title bar per window, decided by what the client negotiated (plugin work item P9, docs/specs/
# compositor.md FR3e; owner report on 1.0.0-rc6: Telegram and the ArtCraft suite showed two title bars). A client that asks for
# client-side decorations (xdg-decoration client_side, KDE server-decoration client: GTK header bars) or negotiates nothing
# (a Qt frameless window: Telegram) gets the client-chrome tag from the plugin, so the plugin's titlebar steps aside; a
# client that asks for server-side decorations keeps the plugin's titlebar.
#
# Usage: tests/compositor/decorations.sh [--plugin PATH]   (PATH: the library the session loaded, for D10's unload and load;
# default compositor/build/grassfield-compositor.so)
# NESTED only, bare: needs scripts/dev/nested-up.sh with the plugin loaded. Clients start through scripts/dev/isolated.sh on
# the nested socket; hyprctl only through scripts/nestctl (read-only, plus window moves and the plugin's unload and load).
#   D1 foot (xdg-decoration server_side): no client-chrome tag
#   D2 xdgact server_side: no tag                 D3 xdgact client_side: the tag (Chromium's and Electron's request)
#   D4 xdgact negotiating nothing: the tag
#   D5 a Qt frameless window (tests/compositor/decorations-fixture, the Telegram stand-in): the tag
#   D6 a plain Qt window (Qt asks for server_side): no tag
#   D7 a GTK 3 header bar (tests/fixtures/gtk-headerbar.py; KDE server-decoration client): the tag
#   D8 a plain GTK 3 window (KDE server-decoration server): no tag
#   D9 a capture: the plugin's strip above foot, none above the Qt frameless window (the row 4 px under the strip's top
#      and 4 px above the surface, at 20-80 % of its width, against the strip's colours, as client_chrome.sh measures)
#   D10 the plugin unloaded: the tag it added is gone (gate C2), a session rule's tag stays; loaded again: back
# Exit: 0 PASS, 1 FAIL, 2 usage or environment error. Log: .dev/decorations/run-<timestamp>.log.
set -uo pipefail

root=$(git -C "$(dirname "$0")" rev-parse --show-toplevel)
dev=$root/.dev
out=${DECO_OUTPUT:-GF-REF}
# shellcheck source=../../scripts/dev/pidfile.sh
. "$root/scripts/dev/pidfile.sh"
# shellcheck source=titlebar_geometry.sh
. "$root/tests/compositor/titlebar_geometry.sh" || exit 2
dev_nested_target "$dev" || exit 2
sock=$DEV_NESTED_SOCK sig=$DEV_NESTED_SIG hypr_pid=$DEV_NESTED_PID
main=$(cat "$dev/main.instance" 2>/dev/null || true)
if [[ $sig == "$main" || $sig == "${HYPRLAND_INSTANCE_SIGNATURE:-}" || $sock == "${WAYLAND_DISPLAY:-}" ]]; then
  echo "decorations: refusing: recorded nested instance is the main session" >&2
  exit 2
fi
bus=$(cat "$dev/bus.address" 2>/dev/null || echo disabled:)

work=$dev/decorations
mkdir -p "$work"
log=$work/run-$(date +%Y%m%d-%H%M%S).log
say() { printf '%s %s\n' "$(date '+%H:%M:%S')" "$*" | tee -a "$log"; }
ctl() { timeout 10 "$root/scripts/nestctl" "$@"; }
pointer() { timeout 30 "$root/scripts/dev/pointer.sh" output "$out" "$@" >>"$log" 2>&1; }

plugin_path=$root/compositor/build/grassfield-compositor.so
[[ ${1:-} == --plugin ]] && plugin_path=${2:?--plugin needs the path the session loaded}
ctl -j plugin list 2>/dev/null | jq -e '[.[]? | select(.name == "grassfield-compositor")] | length > 0' >/dev/null ||
  { echo "decorations: the plugin is not loaded" >&2; exit 2; }
read -r mon_x mon_y mon_scale < <(ctl monitors -j | jq -r --arg o "$out" '.[] | select(.name == $o) | "\(.x) \(.y) \(.scale)"')
[[ -n ${mon_x:-} ]] || { echo "decorations: output $out not found" >&2; exit 2; }

pids=()
cleanup() {
  local p
  for p in "${pids[@]}"; do pkill -P "$p" 2>/dev/null; kill "$p" 2>/dev/null; done
  # A failed D10 must not leave the session without its plugin.
  ctl -j plugin list 2>/dev/null | jq -e '[.[]? | select(.name == "grassfield-compositor")] | length > 0' >/dev/null 2>&1 ||
    ctl plugin load "$plugin_path" >>"$log" 2>&1
}
trap cleanup EXIT

fail=0
check() { if [[ $2 == 0 ]]; then say "  $1: OK   ($3)"; else say "  $1: FAIL ($3)"; fail=1; fi; }
# "<address> <tags joined by ,>" of the window titled $1.
window_of() { ctl clients -j | jq -r --arg t "$1" '[.[] | select(.title == $t)][0] | select(. != null) | "\(.address) \(.tags | join(","))"'; }
wait_window() { local i; for i in $(seq 1 80); do [[ -n $(window_of "$1") ]] && return 0; sleep 0.25; done; return 1; }
has_tag() { # <title>: the window carries the client-chrome tag (the plugin's static one or a rule's dynamic one, with "*")
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
    setsid "$root/scripts/dev/isolated.sh" --name "deco-$name" -- "$@" >>"$log" 2>&1 </dev/null &
  pids+=($!)
}
run_xdgact() { # <decoration: server|client|none> <app id>: xdgact.sh targets the verified nested socket itself
  env -u WAYLAND_DISPLAY XDGACT_DECORATION="$1" setsid "$root/scripts/dev/isolated.sh" --name "deco-xdg-$1" -- "$xdgact" "$2" >>"$log" 2>&1 </dev/null &
  pids+=($!)
}
# The client titled $1 maps; its tag is $2 (1 present, 0 absent).
expect_tag() { # <title> <0|1> <case> <what>
  local t=$1 want=$2 got=0
  if ! wait_window "$t"; then check "$3 $4" 1 "the window '$t' did not map"; return; fi
  sleep 0.6 # the tag follows the client's first commits
  has_tag "$t" && got=1
  check "$3 $4" "$([[ $got == "$want" ]] && echo 0 || echo 1)" "tags '$(window_of "$t" | cut -d' ' -f2)', want the tag: $want"
}
# The plugin strip above a surface (client_chrome.sh's measure, in device px): 1 when both rows have the strip's colour.
strip_above() { # <png> <x> <y> <w> (logical px relative to the output)
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
place() { # <title> <x> <y> (logical, relative to the output)
  local a
  a=$(window_of "$1" | cut -d' ' -f1)
  ctl dispatch "hl.dsp.window.move({ x = $((mon_x + $2)), y = $((mon_y + $3)), window = 'address:$a' })" >>"$log" 2>&1
}

say "decorations: nested pid $hypr_pid, instance $sig, output $out (scale $mon_scale), plugin $plugin_path"
pointer abs 400 400 sleep 100 # new windows open on $out

xdgact=$root/tests/tools/xdgact/xdgact.sh
"$xdgact" --build >>"$log" 2>&1 || { say "setup error: xdgact did not build"; exit 2; }
qml=$root/tests/compositor/decorations-fixture/Window.qml

run_client foot foot -T gf-deco-foot -w 600x360 sh -c 'exec sleep 100000'
expect_tag gf-deco-foot 0 D1 "foot (xdg server_side) keeps the plugin's titlebar"
run_xdgact server gf-deco-xdg-server
expect_tag gf-deco-xdg-server 0 D2 "xdg-decoration server_side keeps the plugin's titlebar"
run_xdgact client gf-deco-xdg-client
expect_tag gf-deco-xdg-client 1 D3 "xdg-decoration client_side: the plugin steps aside"
run_xdgact none gf-deco-xdg-none
expect_tag gf-deco-xdg-none 1 D4 "nothing negotiated: the plugin steps aside"
if command -v qml6 >/dev/null; then
  run_client qt-frameless qml6 "$qml" -- gf-deco-qt-frameless
  expect_tag gf-deco-qt-frameless 1 D5 "a Qt frameless window (Telegram's kind): the plugin steps aside"
  run_client qt-plain qml6 "$qml" -- gf-deco-qt-plain
  expect_tag gf-deco-qt-plain 0 D6 "a plain Qt window (server_side) keeps the plugin's titlebar"
else
  say "  D5, D6: SKIP (qml6 not installed)"
fi
if python3 -c 'import gi; gi.require_version("Gtk", "3.0")' 2>/dev/null; then
  run_client gtk-header python3 -I "$root/tests/fixtures/gtk-headerbar.py" 3 0 gf-deco-gtk-header
  # gtk-headerbar.py titles every window "gtk-headerbar"
  expect_tag gtk-headerbar 1 D7 "a GTK 3 header bar (KDE client): the plugin steps aside"
  run_client gtk-plain python3 -I -c '
import gi
gi.require_version("Gtk", "3.0")
from gi.repository import Gtk
w = Gtk.Window(title="gf-deco-gtk-plain")
w.set_default_size(420, 220)
w.add(Gtk.Label(label="plain"))
w.connect("destroy", Gtk.main_quit)
w.show_all()
Gtk.main()'
  expect_tag gf-deco-gtk-plain 0 D8 "a plain GTK 3 window (KDE server) keeps the plugin's titlebar"
else
  say "  D7, D8: SKIP (python GTK 3 not available)"
fi

# D9: the strip, measured on a capture with the two windows apart.
if [[ -n $(window_of gf-deco-qt-frameless) ]]; then
  place gf-deco-foot 60 120
  place gf-deco-qt-frameless 760 160
  sleep 0.8
  read -r fx fy fw < <(ctl clients -j | jq -r --arg t gf-deco-foot --argjson mx "$mon_x" --argjson my "$mon_y" '[.[] | select(.title == $t)][0] | "\(.at[0] - $mx) \(.at[1] - $my) \(.size[0])"')
  read -r qx qy qw < <(ctl clients -j | jq -r --arg t gf-deco-qt-frameless --argjson mx "$mon_x" --argjson my "$mon_y" '[.[] | select(.title == $t)][0] | "\(.at[0] - $mx) \(.at[1] - $my) \(.size[0])"')
  WAYLAND_DISPLAY=$sock timeout 10 grim -o "$out" "$work/strip.png" 2>>"$log"
  f_strip=$(strip_above "$work/strip.png" "$fx" "$fy" "$fw")
  q_strip=$(strip_above "$work/strip.png" "$qx" "$qy" "$qw")
  [[ $f_strip == 1 && $q_strip == 0 ]]
  check "D9 one title bar each: the plugin's strip above foot, none above the frameless window" $? "above foot: $f_strip (want 1), above the frameless window: $q_strip (want 0); capture $work/strip.png"
fi

# D10: gate C2. The plugin removes the tag it added and nothing else; a reload adds it again.
ctl plugin unload "$plugin_path" >>"$log" 2>&1
sleep 1
has_tag gf-deco-xdg-none
gone=$?
check "D10 unloaded: the tag the plugin added is gone" "$([[ $gone != 0 ]] && echo 0 || echo 1)" "tags '$(window_of gf-deco-xdg-none | cut -d' ' -f2)'"
ctl plugin load "$plugin_path" >>"$log" 2>&1
sleep 1.5
has_tag gf-deco-xdg-none
check "D10 loaded again: the tag is back" $? "tags '$(window_of gf-deco-xdg-none | cut -d' ' -f2)'"
has_tag gf-deco-xdg-server
check "D10 loaded again: still no tag on the server_side window" "$(($? == 0))" "tags '$(window_of gf-deco-xdg-server | cut -d' ' -f2)'"
ctl -j grassfield >/dev/null 2>&1
check "D10 the plugin answers after the reload" $? "hyprctl grassfield"

say "decorations: plugin log: $(ctl rollinglog 2>/dev/null | grep -a 'negotiated' | tail -n 8 | sed 's/.*\[grassfield\] //' | tr '\n' ';')"
say "decorations: $([[ $fail == 0 ]] && echo PASS || echo FAIL)"
exit "$fail"
