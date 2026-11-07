#!/usr/bin/env bash
# L1 nested scenario: one title bar per window, decided by what the client negotiated (plugin work item P9, docs/specs/
# compositor.md; owner report on 1.0.0-rc6: Telegram and the ArtCraft suite showed two title bars). Only a request that proves
# the client draws its own bar tags the window: a KDE server-decoration client request (GTK header bars) or a decoration
# manager bound and no decoration object in the client (a Qt frameless window: Telegram). Everything else keeps the
# plugin's titlebar, an xdg client_side request and no negotiation at all included (review of 3ca47a4b: imv and
# foot -o csd.preferred=client draw no bar of their own and had lost every title bar). The invariant checked on the capture:
# no window ends with neither its own bar nor the plugin's.
#
# Usage: tests/compositor/decorations.sh [--plugin PATH]   (PATH: the library the session loaded, for D10's unload and load;
# default compositor/build/grassfield-compositor.so)
# NESTED only, bare: needs scripts/dev/nested-up.sh with the plugin loaded. Clients start through scripts/dev/isolated.sh on
# the nested socket; hyprctl only through scripts/nestctl (read-only, plus window moves and the plugin's unload and load).
#   D1 foot (xdg-decoration server_side): no client-chrome tag
#   D2 xdgact server_side: no tag
#   D3 xdgact client_side, drawing nothing (foot -o csd.preferred=client's case): no tag, the plugin's titlebar stays
#   D4 xdgact with the manager bound and no decoration object in the client (what Qt does for a frameless window): the tag
#   D4b xdgact that binds no decoration manager (imv's case): no tag
#   D5 a Qt frameless window (tests/compositor/decorations-fixture, the Telegram stand-in): the tag
#   D6 a plain Qt window (Qt asks for server_side): no tag
#   D7 a GTK 3 header bar (tests/fixtures/gtk-headerbar.py; KDE server-decoration client): the tag
#   D8 a plain GTK 3 window (KDE server-decoration server): no tag
#   D11 foot -o csd.preferred=client (asks client_side, draws nothing under Hyprland's server_side answer): no tag
#   D12 imv, Omarchy's image viewer (binds no decoration manager, draws nothing): no tag
#   D9 a capture (each window raised, imv closed): the plugin's strip above foot, above foot -o csd.preferred=client and above the xdgact window that binds no
#      manager, none above the Qt frameless window (the row 4 px under the strip's top and 4 px above the surface, at 20-80 % of
#      its width, against the strip's colours, as client_chrome.sh measures)
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
run_xdgact() { # <decoration: server|client|none|unbound> <app id>: xdgact.sh targets the verified nested socket itself
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
expect_tag gf-deco-xdg-client 0 D3 "xdg-decoration client_side alone proves no bar: the plugin's titlebar stays"
run_xdgact none gf-deco-xdg-none
expect_tag gf-deco-xdg-none 1 D4 "a decoration manager bound, no decoration object (Qt's frameless window): the plugin steps aside"
run_xdgact unbound gf-deco-xdg-unbound
expect_tag gf-deco-xdg-unbound 0 D4b "no decoration manager bound (imv's case): the plugin's titlebar stays"
run_client foot-csd foot -o csd.preferred=client -T gf-deco-foot-csd -w 600x360 sh -c 'exec sleep 100000'
expect_tag gf-deco-foot-csd 0 D11 "foot -o csd.preferred=client (asks client_side, draws nothing here): the plugin's titlebar stays"
if command -v imv-wayland >/dev/null && command -v magick >/dev/null; then
  magick -size 320x200 xc:'#3a6ea5' "$work/imv.png" 2>>"$log"
  run_client imv imv-wayland "$work/imv.png"
  # imv titles its window "imv - [1/1] <path> ..."
  imv_title=""
  for _ in $(seq 1 40); do
    imv_title=$(ctl clients -j | jq -r '[.[] | select(.class == "imv")][0].title // empty')
    [[ -n $imv_title ]] && break
    sleep 0.25
  done
  if [[ -n $imv_title ]]; then
    expect_tag "$imv_title" 0 D12 "imv (no decoration manager bound, draws nothing): the plugin's titlebar stays"
    # imv opens at its picture's zoom (most of the output): closed, so that it covers none of D9's windows.
    imv_pid=$(ctl clients -j | jq -r '[.[] | select(.class == "imv")][0].pid // empty')
    [[ -n $imv_pid ]] && kill "$imv_pid" 2>/dev/null
  else
    check "D12 imv mapped" 1 "no window of class imv"
  fi
else
  say "  D12: SKIP (imv-wayland or magick not installed)"
fi
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
  # Reported, not judged: what an undecorated GTK 3 window (gtk_window_set_decorated(FALSE): a Tauri app without decorations,
  # a splash) negotiates and whether it is tagged. It asked for no decorations at all; the plugin follows its request.
  run_client gtk-undecorated python3 -I -c '
import gi
gi.require_version("Gtk", "3.0")
from gi.repository import Gtk
w = Gtk.Window(title="gf-deco-gtk-undecorated")
w.set_decorated(False)
w.set_default_size(420, 220)
w.add(Gtk.Label(label="undecorated"))
w.connect("destroy", Gtk.main_quit)
w.show_all()
Gtk.main()'
  if wait_window gf-deco-gtk-undecorated; then
    sleep 0.6
    say "  note: an undecorated GTK 3 window: tags '$(window_of gf-deco-gtk-undecorated | cut -d' ' -f2)'"
  fi
else
  say "  D7, D8: SKIP (python GTK 3 not available)"
fi

# D9: the strip, measured on a capture with the windows apart (each at its own place on the headless output: the capture never
# depends on the nested window's frames). The invariant: every window shows its own bar or the plugin's.
strip_of() { # <title> <x> <y>: placed there and raised above every other window, then measured on the capture taken by D9
  local a
  place "$1" "$2" "$3"
  a=$(window_of "$1" | cut -d' ' -f1)
  ctl dispatch "hl.dsp.window.alter_zorder({ mode = 'top', window = 'address:$a' })" >>"$log" 2>&1
}
geom_rel() { ctl clients -j | jq -r --arg t "$1" --argjson mx "$mon_x" --argjson my "$mon_y" '[.[] | select(.title == $t)][0] | select(. != null) | "\(.at[0] - $mx) \(.at[1] - $my) \(.size[0])"'; }
if [[ -n $(window_of gf-deco-qt-frameless) ]]; then
  strip_of gf-deco-foot 40 80
  strip_of gf-deco-qt-frameless 700 80
  strip_of gf-deco-foot-csd 40 500
  strip_of gf-deco-xdg-unbound 700 500
  sleep 0.8
  WAYLAND_DISPLAY=$sock timeout 10 grim -o "$out" "$work/strip.png" 2>>"$log"
  verdict=0 detail=""
  for spec in gf-deco-foot:1 gf-deco-qt-frameless:0 gf-deco-foot-csd:1 gf-deco-xdg-unbound:1; do
    t=${spec%:*} want=${spec#*:}
    read -r gx gy gw < <(geom_rel "$t")
    got=$(strip_above "$work/strip.png" "${gx:-0}" "${gy:-0}" "${gw:-0}")
    detail+="$t $got (want $want); "
    [[ $got == "$want" ]] || verdict=1
  done
  check "D9 one title bar each: the plugin's strip above foot, foot -o csd.preferred=client and the window binding no manager, none above the Qt frameless window" "$verdict" "${detail}capture $work/strip.png"
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
