#!/usr/bin/env bash
# L1 nested scenario (GF-056; ADR-0015 amendment 2026-10-25): an app on the session's third-party list draws its own window
# controls and gets no second set; every other window keeps the plugin's titlebar. macOS: one set of traffic lights,
# top-left: close, minimize, zoom.
#
# Usage: tests/compositor/third_party_chrome.sh
# NESTED only, bare: needs scripts/dev/nested-up.sh with the plugin and its private bus (.dev/bus.address). Every client
# starts through scripts/dev/isolated.sh (isolated homes, the dev dconf profile of scripts/dev/devenv.sh) on the private
# bus and the nested socket, never the owner's bus or home; Chromium with a throwaway profile under .dev/. hyprctl only
# through scripts/nestctl (read-only, plus window moves); captures with grim.
# Offline: a test never touches the network. Every client gets the discard port (127.0.0.1:9, nothing listens) as its
# proxy: the proxy variables for GIO, libproxy and curl-based code, --proxy-server for Chromium and Electron (they obey it
# over the environment; nothing passes --no-proxy-server, which would override it, and the isolated homes, fresh every
# run, hold no chromium-flags.conf or obsidian user-flags.conf that could). Chromium also runs with its background
# networking, component updater and sync off. Obsidian's own updater is off (updateDisabled in its obsidian.json, the key
# its main process reads); its log must show the installed package and no update check. Before this, Obsidian updated
# itself from GitHub during the run (an asar in its isolated home, loaded instead of the installed version).
#
# Per app on the list that is installed (Evince: GTK3 header bar; Nautilus: GTK4/libadwaita; Chromium's browser window:
# its GTK integration; Obsidian: Electron, its starter window and a vault window on a temporary vault), one at a time at
# the same place:
#   T  SESSION  its class carries the Hyprland tag grassfield-client-chrome (rule gf-client-chrome-third-party)
#   S  PLUGIN   no plugin strip above it (the measurement of client_chrome.sh)
#   Z  SESSION  its own zoom button zooms it, a second press restores it. Zoom is Fill (ADR-0036 D78, ADR-0015 Q4 amended):
#               with the plugin's zoom-fill the request is the plugin's (fullscreen 0, larger on both axes; a window of fixed
#               size, Obsidian's starter, is left as it is: its zoom does nothing, as a disabled zoom light on macOS);
#               without it Hyprland's maximized mode (fullscreen=1, exempt from the maximize suppression)
#   M  PLUGIN   its own minimize button puts it on special:minimized (xdg set_minimized, the client-chrome bridge P5),
#               toward the Dock tile the shell computed (the plugin's log line, as for the titlebar's minimize light).
#               GTK4 greys a minimize button the compositor does not offer: Nautilus's works only with P8 (minimize in
#               its xdg wm_capabilities)
#   D  PLUGIN   a click on that Dock tile restores it: back on its Desktop, at its geometry, focused
#   C  client   its own close button, pressed last, closes the window
#   V  visual   a capture of its top band, .dev/third-party-chrome/<app>-top.png: its own close, minimize, zoom. The
#               script cannot judge a picture: it prints "visual NOT verified" with the path; whoever runs it judges the
#               captures and records the verdict.
# The Dock is brought to the output first (the pointer rests on its bottom edge, as minimize.sh's dock_to): a session
# started with the focus on the small WAYLAND-1 has its Dock there. Clicks come after a fresh pointer motion: a window
# moved under a resting pointer has no pointer focus, and a click there is lost.
# Firefox (firefox, org.mozilla.firefox) left the list on the rc7 audit (ADR-0015 amendment 2026-11-08): the plugin reads its
# negotiation. A foot window with its app id asks for server-side decorations, as Firefox with its "Title Bar" option does,
# and keeps the plugin's titlebar (not tagged, the strip above it); Firefox's two modes are frameless_chrome.sh's F4, F5. Its
# own buttons are NOT VERIFIED (not installed here). Google Chrome is not run here (not installed).
# Not on the list, the plugin's titlebar kept (not tagged, the strip above them): foot; a Chromium web app (--app: no
# frame of its own).
# The layout the clients are given: org.gnome.desktop.wm.preferences button-layout read in a client's environment
# (GSettings through the dev profile) and through the settings portal on the private bus (what GTK4 and Chromium read),
# both 'close,minimize,maximize:' (ADR-0002, packaging/dconf/grassfield.d/20-window-buttons.conf).
# Exit: 0 PASS (every automatic check; the captures still need a look), 1 FAIL, 2 usage or environment error.
set -uo pipefail

root=$(git -C "$(dirname "$0")" rev-parse --show-toplevel)
dev=$root/.dev
out=${TPC_OUTPUT:-GF-REF}
want_layout="'close,minimize,maximize:'"

# shellcheck source=../../scripts/dev/pidfile.sh
. "$root/scripts/dev/pidfile.sh"
# shellcheck source=titlebar_geometry.sh
. "$root/tests/compositor/titlebar_geometry.sh" || exit 2
dev_nested_target "$dev" || exit 2
sock=$DEV_NESTED_SOCK sig=$DEV_NESTED_SIG hypr_pid=$DEV_NESTED_PID
main=$(cat "$dev/main.instance" 2>/dev/null || true)
if [[ -z $sock || -z $sig || -z $hypr_pid ]] || ! kill -0 "$hypr_pid" 2>/dev/null; then
  echo "third_party_chrome: no nested instance (run scripts/dev/nested-up.sh)" >&2
  exit 2
fi
if [[ $sig == "$main" || $sig == "${HYPRLAND_INSTANCE_SIGNATURE:-}" || $sock == "${WAYLAND_DISPLAY:-}" ]]; then
  echo "third_party_chrome: refusing: recorded nested instance is the main session" >&2
  exit 2
fi
bus=$(cat "$dev/bus.address" 2>/dev/null || true)
case $bus in
  unix:path=/tmp/dbus-*) ;;
  *) echo "third_party_chrome: no private bus (.dev/bus.address; nested-up.sh starts it)" >&2; exit 2 ;;
esac

work=$dev/third-party-chrome
rm -rf "$work"
mkdir -p "$work"
# Fresh isolated homes every run: nothing a previous run left there (an app's own update, a flags file) changes what is
# tested.
for n in layout foot evince nautilus chromium obsidian; do rm -rf "$dev/isolated/tpc-$n"; done
dead_proxy=127.0.0.1:9
log=$work/run-$(date +%Y%m%d-%H%M%S).log
say() { printf '%s %s\n' "$(date '+%H:%M:%S')" "$*" | tee -a "$log"; }
pointer() { timeout 20 "$root/scripts/dev/pointer.sh" output "$out" "$@" >>"$log" 2>&1; }
ctl() { timeout 10 "$root/scripts/nestctl" "$@"; }
# A client on the nested socket and the private bus, isolated (scripts/dev/isolated.sh): <name> <command...>
client_run() {
  local name=$1 p=http://$dead_proxy; shift
  http_proxy=$p https_proxy=$p all_proxy=$p HTTP_PROXY=$p HTTPS_PROXY=$p ALL_PROXY=$p no_proxy='' NO_PROXY='' \
    WAYLAND_DISPLAY=$sock DBUS_SESSION_BUS_ADDRESS=$bus GDK_BACKEND=wayland ELECTRON_OZONE_PLATFORM_HINT=wayland \
    setsid "$root/scripts/dev/isolated.sh" --name "tpc-$name" -- "$@" >>"$log" 2>&1 </dev/null &
  echo $!
}
# The same environment, in the foreground (a query): <name> <command...>
client_query() {
  local name=$1; shift
  WAYLAND_DISPLAY=$sock DBUS_SESSION_BUS_ADDRESS=$bus timeout 20 "$root/scripts/dev/isolated.sh" --name "tpc-$name" -- "$@" 2>>"$log"
}

read -r mon_x mon_y mon_w mon_h < <(ctl monitors -j | jq -r --arg o "$out" '.[] | select(.name == $o) | "\(.x) \(.y) \(.width) \(.height)"')
[[ -n ${mon_w:-} ]] || { echo "third_party_chrome: output $out not found" >&2; exit 2; }
ctl -j plugin list | jq -e '[.[]? | select(.name == "grassfield-compositor")] | length > 0' >/dev/null \
  || { echo "third_party_chrome: the plugin is not loaded" >&2; exit 2; }

pids=()
# An anchor pointer for the whole run (as in minimize.sh): the seat keeps its pointer while pointer.sh adds and removes its
# own devices, so clients keep their wl_pointer.
"$root/scripts/dev/pointer.sh" output "$out" sleep 3600000 >>"$log" 2>&1 &
pids+=($!)
# Hyprland's log as it is written (read-only), line-buffered: the plugin's line with the Dock rectangle of each minimize.
follow=$work/hyprland-follow.log
timeout 3600 stdbuf -oL "$root/scripts/nestctl" rollinglog -f >"$follow" 2>&1 &
pids+=($!)
cleanup() {
  local p
  for p in "${pids[@]}"; do pkill -P "$p" 2>/dev/null; kill "$p" 2>/dev/null; done
  pkill -f -- "--user-data-dir=$work/chromium-profile" 2>/dev/null
}
trap cleanup EXIT

fail=0 visual=()
check() { if [[ $2 == 0 ]]; then say "  $1: OK   ($3)"; else say "  $1: FAIL ($3)"; fail=1; fi; }

client() { ctl clients -j | jq -r --arg c "$1" ".[] | select(.class | test(\$c)) | $2" | head -1; }
geom() {
  ctl clients -j | jq -r --arg c "$1" --argjson mx "$mon_x" --argjson my "$mon_y" \
    '.[] | select(.class | test($c)) | "\(.at[0] - $mx) \(.at[1] - $my) \(.size[0]) \(.size[1]) \(.fullscreen)"' | head -1
}
wait_mapped() { local i; for i in $(seq 1 ${2:-60}); do [[ -n $(client "$1" .address) ]] && return 0; sleep 0.25; done; return 1; }
wait_gone() { local i; for i in $(seq 1 40); do [[ -z $(client "$1" .address) ]] && return 0; sleep 0.25; done; return 1; }
place() { # <class regex> <x> <y> (output px)
  ctl dispatch "hl.dsp.window.move({ x = $((mon_x + $2)), y = $((mon_y + $3)), window = 'address:$(client "$1" .address)' })" >>"$log" 2>&1
  sleep 0.8
}
# The plugin strip above a surface (as in client_chrome.sh): 1 when two rows of the strip have the strip's colour at five
# points across the window, 0 otherwise. <png> <x> <y> <w> (output px).
strip_above() {
  local i r hexes=()
  for r in 4 $((GF_TB_HEIGHT - 4)); do
    for i in 20 35 50 65 80; do
      hexes+=("$(magick "$1" -format "%[hex:p{$(($2 + $4 * i / 100)),$(($3 - r))}]" info: 2>/dev/null | cut -c1-6)")
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
# One window at (160,140): its tag, the strip above it, a capture of its top band. <label> <class regex> <tagged 0|1>
judge() {
  local label=$1 cls=$2 tagged=$3 x y w h tags strip
  place "$cls" 160 140
  read -r x y w h _ < <(geom "$cls")
  tags=$(client "$cls" '.tags | join(",")')
  WAYLAND_DISPLAY=$sock timeout 10 grim -o "$out" "$work/$label.png" 2>>"$log"
  strip=$(strip_above "$work/$label.png" "$x" "$y" "$w")
  magick "$work/$label.png" -crop "${w}x$((GF_TB_HEIGHT + 70))+${x}+$((y - GF_TB_HEIGHT))" +repage "$work/$label-top.png" 2>>"$log"
  if ((tagged)); then
    [[ $tags == *grassfield-client-chrome* ]]
    check "$label: tagged (SESSION)" $? "class $(client "$cls" .class), tags '$tags'"
    [[ $strip == 0 ]]
    check "$label: no plugin strip (PLUGIN)" $? "strip above ${w}x${h} at ($x,$y): $strip"
    visual+=("$label: its own close, minimize and zoom, one set (left in macOS order when the app follows the GTK layout): $work/$label-top.png")
  else
    [[ $tags != *grassfield-client-chrome* ]]
    check "$label: not tagged" $? "class $(client "$cls" .class), tags '$tags'"
    [[ $strip == 1 ]]
    check "$label: the plugin strip" $? "strip above ${w}x${h} at ($x,$y): $strip"
    visual+=("$label: the plugin's traffic lights (and, for a header-bar app, its own buttons too): $work/$label-top.png")
  fi
}
# A click at <x> <y> (output px) after a fresh motion from the side of the output.
press() {
  pointer abs $((mon_w - 40)) $((mon_h / 2)) sleep 150
  pointer abs $(($1 - 4)) $(($2 - 3)) sleep 120
  pointer abs "$1" "$2" sleep 150 click
}
# The Dock on this output: the pointer rests on its bottom edge for longer than Tokens.dockRevealDwell, then leaves it.
dock_here() {
  pointer abs $((mon_w / 2)) $((mon_h / 2)) sleep 500
  pointer abs $((mon_w / 2)) $((mon_h - 1)) sleep 1200
  pointer abs $((mon_w / 2)) $((mon_h / 2)) sleep 600
}
follow_lines() { grep -ac "" "$follow" 2>/dev/null || echo 0; }
# Centre of the Dock tile the shell sent with the latest minimize of <hex> (after line <since> of the follow log), as
# "x y" on this output; waits up to 3 s; nothing without that line or when the tile is on another output.
dock_tile() { # <hex address, no 0x> <since>
  local line rect rx ry rw rh deadline=$(($(date +%s%3N) + 3000))
  while :; do
    line=$(tail -n +"$(($2 + 1))" "$follow" 2>/dev/null | grep -a "\[grassfield\] minimize $1: toward the Dock rectangle " | tail -n 1)
    [[ -n $line ]] && break
    (($(date +%s%3N) > deadline)) && return 1
    sleep 0.05
  done
  rect=$(sed -n 's/.*toward the Dock rectangle \(-\{0,1\}[0-9]*\),\(-\{0,1\}[0-9]*\) \([0-9]*\)x\([0-9]*\).*/\1 \2 \3 \4/p' <<<"$line")
  [[ -n $rect ]] || return 1
  read -r rx ry rw rh <<<"$rect"
  rx=$((rx + rw / 2 - mon_x)) ry=$((ry + rh / 2 - mon_y))
  ((rx >= 0 && rx < mon_w && ry >= 0 && ry < mon_h)) && echo "$rx $ry"
}
# The app's own buttons work: <label> <class regex> <close dx> <minimize dx> <zoom dx> <dy> [first|right] (offsets from
# the window's top-left; a negative dx counts from its right edge: at the window's first width, kept from its left edge,
# with `first`, the default; at its current width with `right`, for a resizable window whose controls follow its edge).
own_buttons() {
  local label=$1 cls=$2 cdx=$3 mdx=$4 zdx=$5 dy=$6 anchor=${7:-first} fs1 fs2 ws w0 x0 y0 h0 ws0 addr f0 tx ty x y w h active
  # `first`: Obsidian's starter window is not resizable, its content (and its controls) stays at its size in the corner of
  # a zoomed box.
  read -r _ _ w0 _ _ < <(geom "$cls")
  if [[ $anchor == first ]]; then
    ((cdx < 0)) && cdx=$((w0 + cdx))
    ((mdx < 0)) && mdx=$((w0 + mdx))
    ((zdx < 0)) && zdx=$((w0 + zdx))
  fi
  at() { # <dx> -> "x y" (output px), from the window's current left edge (or its current right edge for a negative dx)
    local x y w
    read -r x y w _ _ < <(geom "$cls")
    if (($1 < 0)); then echo "$((x + w + $1)) $((y + dy))"; else echo "$((x + $1)) $((y + dy))"; fi
  }
  local zx0 zy0 zw0 zh0 zx1 zy1 zw1 zh1 zx2 zy2 zw2 zh2 zaddr zfixed=0
  read -r zx0 zy0 zw0 zh0 _ < <(geom "$cls")
  zaddr=$(client "$cls" .address)
  if ctl -j grassfield 2>/dev/null | jq -e '.features | index("zoom-fill")' >/dev/null 2>&1; then
    ctl grassfield-tiling 2>/dev/null | jq -e --arg a "${zaddr#0x}" '(.fixed // []) | index($a) != null' >/dev/null 2>&1 && zfixed=2 || zfixed=1
  fi
  # shellcheck disable=SC2046 # "x y"
  press $(at "$zdx")
  sleep 1
  read -r zx1 zy1 zw1 zh1 fs1 < <(geom "$cls")
  # shellcheck disable=SC2046
  press $(at "$zdx")
  sleep 1
  read -r zx2 zy2 zw2 zh2 fs2 < <(geom "$cls")
  case $zfixed in
    0) [[ $fs1 == 1 && $fs2 == 0 ]] ;;                                                       # Hyprland's maximized mode
    1) [[ $fs1 == 0 && $fs2 == 0 ]] && ((zw1 > zw0 && zh1 > zh0)) && [[ "$zx2 $zy2 $zw2 $zh2" == "$zx0 $zy0 $zw0 $zh0" ]] ;; # Fill and back
    2) [[ $fs1 == 0 && $fs2 == 0 && "$zx1 $zy1 $zw1 $zh1" == "$zx0 $zy0 $zw0 $zh0" ]] ;;      # fixed size: nothing
  esac
  check "$label: its own zoom button zooms and unzooms (SESSION; Fill with zoom-fill)" $? \
    "mode $zfixed (0 Hyprland, 1 Fill, 2 fixed size): ${zw0}x${zh0} at $zx0,$zy0 -> ${zw1}x${zh1} at $zx1,$zy1 fullscreen $fs1 -> ${zw2}x${zh2} at $zx2,$zy2 fullscreen $fs2"
  read -r x0 y0 w0 h0 _ < <(geom "$cls")
  ws0=$(client "$cls" .workspace.name) addr=$(client "$cls" .address)
  f0=$(follow_lines)
  # shellcheck disable=SC2046
  press $(at "$mdx")
  sleep 1.5
  ws=$(client "$cls" .workspace.name)
  [[ $ws == special:minimized ]]
  check "$label: its own minimize button minimizes (PLUGIN P5)" $? "workspace '$ws'"
  read -r tx ty <<<"$(dock_tile "${addr#0x}" "$f0")"
  [[ -n ${ty:-} ]]
  check "$label: toward its Dock tile (the shell's rectangle, plugin log line)" $? "tile centre ${tx:-?},${ty:-?} on $out"
  [[ -n ${ty:-} ]] || return
  WAYLAND_DISPLAY=$sock timeout 10 grim -o "$out" "$work/$label-minimized.png" 2>>"$log"
  pointer abs "$tx" "$ty" sleep 300 # hover first (Dock magnification settles)
  pointer abs "$tx" "$ty" sleep 40 click sleep 1500
  read -r x y w h _ < <(geom "$cls")
  ws=$(client "$cls" .workspace.name) active=$(ctl activewindow -j | jq -r '.address // ""')
  [[ $ws == "$ws0" && $x == "$x0" && $y == "$y0" && $w == "$w0" && $h == "$h0" && $active == "$addr" ]]
  check "$label: its Dock tile restores it (PLUGIN)" $? "now ${w}x${h} at ($x,$y) on '$ws', active $active; was ${w0}x${h0} at ($x0,$y0) on '$ws0'"
  # The effect the settings chose (funnel or shrink; fade with Reduce Motion), from the plugin's timing lines: reported.
  tail -n +"$((f0 + 1))" "$follow" 2>/dev/null | grep -ao "minimize ${addr#0x}: [a-z]* \(minimize\|restore\) in [0-9]* ms, [0-9]* frames" \
    | while IFS= read -r l; do say "  $label: $l"; done
  # Last, on this throwaway window: its own close button.
  # shellcheck disable=SC2046
  press $(at "$cdx")
  wait_gone "$cls"
  check "$label: its own close button closes it" $? "window ${addr} $(client "$cls" .address | grep -q . && echo 'still mapped' || echo gone)"
}
stop_app() { # <pid> <class regex>
  pkill -P "$1" 2>/dev/null; kill "$1" 2>/dev/null
  wait_gone "$2" || say "  ($2 still mapped after the stop)"
}

say "third_party_chrome: nested pid $hypr_pid, instance $sig, output $out ${mon_w}x${mon_h}, bus $bus"
dock_here

say "layout the clients are given"
gs=$(client_query layout gsettings get org.gnome.desktop.wm.preferences button-layout)
[[ $gs == "$want_layout" ]]
check "GSettings in a client's environment (dev profile ${DCONF_PROFILE:-of devenv.sh})" $? "$gs"
# The desktop portal never starts on the private bus (ADR-0011 amendment 2026-10-26: it would start the document portal, which
# unmounts the owner's $XDG_RUNTIME_DIR/doc): GTK4 and Chromium read the layout from GSettings instead, checked above.
portal=$(client_query layout gdbus call --session --dest org.freedesktop.portal.Desktop --object-path /org/freedesktop/portal/desktop \
  --method org.freedesktop.portal.Settings.Read org.gnome.desktop.wm.preferences button-layout 2>&1)
[[ $portal == *Error* && $portal != *"$want_layout"* ]]
check "the desktop portal is refused on the private bus (GTK4 and Chromium fall back to GSettings)" $? "$portal"

say "foot (no frame of its own): the plugin's titlebar"
p=$(client_run foot foot --window-size-pixels=640x300); pids+=("$p")
wait_mapped '^foot$' || { say "setup error: foot did not map"; exit 2; }
judge foot '^foot$' 0
stop_app "$p" '^foot$'

# Firefox (`firefox`; `org.mozilla.firefox` for the Flatpak) joined the list on the owner's rc1-22 screenshot (2026-11-04) and
# left it on the rc7 audit (2026-11-08): listed, its "Title Bar" mode had no controls at all. It is not installed here and not
# downloaded: a foot window with Firefox's Wayland app id asks for server-side decorations, as Firefox's Title Bar mode does,
# and must keep the plugin's titlebar now that no rule tags the class (T, S: no tag, the plugin's strip). Firefox's own frame
# (KDE client) is tagged by the plugin: frameless_chrome.sh F4. That Firefox's own close, minimize and zoom work, and that
# they draw as traffic lights with the Grassfield GTK theme, is NOT VERIFIED: the owner checks it on the second machine.
for id in firefox org.mozilla.firefox; do
  cls="^${id//./\\.}\$"
  p=$(client_run "foot" foot --app-id="$id" --window-size-pixels=640x300); pids+=("$p")
  if wait_mapped "$cls"; then
    say "class $id (a foot window standing in for Firefox's Title Bar mode: server-side decorations asked, the plugin's titlebar)"
    judge "stand-in-$id" "$cls" 0
  else
    check "class $id: mapped" 1 "$(ctl clients -j | jq -c '[.[].class]')"
  fi
  stop_app "$p" "$cls"
done

# Header-bar apps with the session's GTK layout: close, minimize, zoom on the left, 23 px below the window's top.
for gtk in "evince|Evince (GTK3 header bar)|^org\\.gnome\\.Evince$|evince|22|63|101" \
  "nautilus|Nautilus (GTK4/libadwaita header bar)|^org\\.gnome\\.Nautilus$|nautilus --new-window|22|60|97"; do
  IFS='|' read -r label title cls cmd cdx mdx zdx <<<"$gtk"
  command -v "${cmd%% *}" >/dev/null || continue
  say "$title"
  # shellcheck disable=SC2086 # the command and its arguments
  p=$(client_run "$label" $cmd); pids+=("$p")
  # Up to 30 s: on the private bus Nautilus can wait about 12 s for an accessibility bus that never starts.
  if wait_mapped "$cls" 120; then
    sleep 1.5
    judge "$label" "$cls" 1
    own_buttons "$label" "$cls" "$cdx" "$mdx" "$zdx" 23
  else
    check "$label: mapped" 1 "$(ctl clients -j | jq -c '[.[].class]')"
  fi
  stop_app "$p" "$cls"
done

if command -v chromium >/dev/null; then
  cargs=(--user-data-dir="$work/chromium-profile" --no-first-run --no-default-browser-check --password-store=basic
    --disable-background-networking --disable-component-update --disable-sync --proxy-server="$dead_proxy"
    --ozone-platform=wayland --window-size=900,520)
  say "Chromium browser (its own frame, through its GTK integration)"
  p=$(client_run chromium chromium "${cargs[@]}" about:blank); pids+=("$p")
  if wait_mapped '^chromium$' 80; then
    sleep 2
    judge chromium '^chromium$' 1
    own_buttons chromium '^chromium$' 17 50 83 21  # isolation-ok: a label for the judge, not a launch
  else
    check "chromium: mapped as chromium" 1 "$(ctl clients -j | jq -c '[.[].class]')"
  fi
  stop_app "$p" '^chromium$'
  pkill -f -- "--user-data-dir=$work/chromium-profile" 2>/dev/null
  sleep 1
  say "Chromium web app (--app: no frame of its own)"
  printf '<title>gf web app</title><body>web app</body>\n' >"$work/app.html"
  p=$(client_run chromium chromium "${cargs[@]}" --app="file://$work/app.html"); pids+=("$p")
  if wait_mapped '^chrome-' 80; then
    sleep 2
    judge webapp '^chrome-' 0
  else
    check "web app: mapped as chrome-*" 1 "$(ctl clients -j | jq -c '[.[].class]')"
  fi
  stop_app "$p" '^chrome-'
  pkill -f -- "--user-data-dir=$work/chromium-profile" 2>/dev/null
fi

if command -v obsidian >/dev/null; then
  # Its user data directory in the isolated home (Electron's userData: $XDG_CONFIG_HOME/obsidian), with the settings file
  # its main process reads at start: updateDisabled (its updater stays off) and, for the second run, a vault to open.
  obs_cfg=$dev/isolated/tpc-obsidian/config/obsidian
  mkdir -p "$obs_cfg"
  printf '{"updateDisabled":true}\n' >"$obs_cfg/obsidian.json"
  vault=$work/obsidian-vault
  mkdir -p "$vault"
  printf '# Grassfield test note\n' >"$vault/note.md"
  for run in starter vault; do
    if [[ $run == vault ]]; then
      jq -n --arg p "$vault" '{updateDisabled: true, vaults: {"6766746573747661": {path: $p, ts: 1, open: true}}}' >"$obs_cfg/obsidian.json"
      say "Obsidian (Electron, its own frame): a vault window on a temporary vault"
    else
      say "Obsidian (Electron, its own frame): its starter window"
    fi
    p=$(client_run obsidian obsidian --proxy-server="$dead_proxy"); pids+=("$p")
    if wait_mapped '^md\.obsidian\.Obsidian$' 120; then
      sleep 2
      judge "obsidian-$run" '^md\.obsidian\.Obsidian$' 1
      # Obsidian draws its controls at the top right, in its own order (minimize, zoom, close): it ignores the GTK layout.
      # The starter window is not resizable (offsets at its first width); a vault window is, its controls follow its edge.
      if [[ $run == starter ]]; then
        own_buttons obsidian-starter '^md\.obsidian\.Obsidian$' -23 -110 -67 15
      else
        own_buttons obsidian-vault '^md\.obsidian\.Obsidian$' -23 -110 -66 20 right
      fi
    else
      check "obsidian ($run): mapped as md.obsidian.Obsidian" 1 "$(ctl clients -j | jq -c '[.[].class]')"
    fi
    stop_app "$p" '^md\.obsidian\.Obsidian$'
  done
  # Offline and the installed version: its own log (written by its main process in the user data directory).
  obs_log=$(cat "$obs_cfg/obsidian.log" 2>/dev/null)
  obs_asars=$(find "$obs_cfg" -maxdepth 1 -name 'obsidian-*.asar' | wc -l)
  [[ $obs_log == *"Loaded main app package "* && $obs_log != *"Loaded updated app"* && $obs_log != *"Checking for update"* && $obs_asars == 0 ]]
  check "obsidian: the installed package, no update check, nothing downloaded" $? \
    "$(grep -c 'Loaded main app package' <<<"$obs_log") start(s) on the installed package, $(grep -c 'Checking for update' <<<"$obs_log") update check(s), $obs_asars downloaded asar(s)"
fi

say "captures (visual NOT verified by this script: judge each one)"
for v in "${visual[@]}"; do say "  visual NOT verified: $v"; done
say "third_party_chrome: $([[ $fail == 0 ]] && echo PASS || echo FAIL) (automatic checks)"
exit "$fail"
