#!/usr/bin/env bash
# Window tiling (macOS 15+ model, docs/specs/compositor.md FR47-FR50) on GF-REF. The nested layout varies: WAYLAND-1 may
# touch GF-REF's left edge (a fresh session) or its right edge (after tests/compositor/overview_focus.sh), or neither. The
# layout is read first; the edge cases run on a FREE edge (right when free, else left) and the shared-edge case on
# whichever edge another output touches. A foot window is dragged by its titlebar (one pointer invocation per press and
# release):
#   free-edge      released at the free edge: that half of the free area (margins 8, below the menu bar)
#   preview        a capture while the button is still down at the edge shows the frame as the blurred material (D-8):
#                  a pattern window behind it loses its detail (measured), and the capture is kept for the eye
#   drag-out       a drag of the tiled window away from the edge: it gets its size from before back
#   top-corner     released at the top of the free edge: that top quarter
#   shared-edge    released at an edge another output touches: no tiling (the window just moves over); skipped when no
#                  output touches GF-REF
#   other-output   dragged by its titlebar until its middle is on that neighbouring output, then tile(address, "left"):
#                  the left half of THAT output (the plugin's own drag does not update Hyprland's window monitor, R13)
#   menu-bar       released on the menu bar: the free area is filled
#   menu-bar-at-once  (1.0.0-rc6 report) released 60 ms after reaching the menu bar, no output above: filled (no delay there)
#   drag-follows   (same report) a capture right after a jump of the pointer during the titlebar drag: the window is under it
#   ipc            hl.plugin.grassfield.tile(address, "left"), then "previous": the left half, then the size from before
#   options        with tilingEdges false a drag to the right edge does not tile
# Step 1 (docs/specs/tiling.md TL1-TL15; only when the plugin advertises tiling-arrange; a second foot window):
#   state          `hyprctl grassfield-tiling` lists GF-REF with its work area and grid
#   arrange        arrange({layout:"left-right", windows:[first]}): the first window takes the left half, the next window
#                  in stacking order the right half; both are one tile group in the state reply
#   invalid        an arrange with an unknown layout changes nothing (generation and boxes kept)
#   margins        tilingMargins false places the arrangement again without margins, true with them
#   full-screen    full screen suspends the tile; leaving it puts the window back in its tile (TL12)
#   minimize       a move to special:minimized suspends it; back on its Desktop it returns to its free zone (TL14)
#   zone-taken     minimized again, its zone taken by the other window: back on its Desktop it is Free at its size
#                  from before (TL10)
#   locked         while the foreign locker fixture holds the session lock (tests/security/foreign_locker, released over
#                  its IPC, nothing typed), tile and arrange move nothing and leave the records unchanged (TL34, D4)
# Step 2 (docs/specs/tiling.md TL16-TL20; only with tiling-arrange: Hyprland's moves need the tiling listeners). Super is
# held with scripts/dev/keys.sh (Super+drag is Hyprland's move, bindings.lua), Alt likewise:
#   super-drag     Hyprland's move released at the free edge after the preview delay: that half, a tile record
#   super-out      Hyprland's move of that tiled window to the middle: its size from before, the grip kept under the
#                  pointer (the drag ended and begun again), Free
#   delay          released at the edge before the preview delay (Hyprland's move, then the titlebar drag): no tile
#   alt-drag       the titlebar drag released in the middle with Alt held (no delay): the half on the pointer's side
#   menu-bar-move  Hyprland's move released on the menu bar: Fill (the top clamp leaves the window to the tile)
#   edge           a double-click on the right resize border: the right side at the work area's edge, `sides` "right"
#   alt-corner     an Alt double-click on the bottom-right corner: Fill
#   chromium       Chromium (client chrome: its tab strip asks Hyprland's move) dragged to the free edge: that half, the
#                  preview captured while held; dragged out by its tab strip: its size from before (skipped without it)
#   unload         the plugin unloaded in the middle of Hyprland's move: Hyprland alive, the drag goes on as Hyprland's
#                  own; loaded again
# Step 3 (docs/specs/tiling.md TL22-TL26; only with tile-hover). The plugin's events are read on Hyprland's socket2 (socat);
# the shell's popover, when the shell runs, is closed with Esc after each case:
#   popover-verb   tile_popover(address) posts tile-hover "open" for the window, tileable, its light in the titlebar's band
#   hover          the pointer on that light: no "enter" before tiling.hoverDelay, "enter" after it; moving away posts
#                  "leave"
#   layouts-off    (step 5, TL32) config tilingLayouts false: the pointer resting on the light posts no "enter";
#                  tile_popover still posts "open"; then true again
#   fixed          (ADR-0040 step 1b) About This Computer (grassfield-settings --about, minimum = maximum): listed in the
#                  reply's "fixed"; tile_popover, the pointer resting on its disabled zoom light and a click there post no
#                  tile-hover and open no shell popup, its box unchanged (skipped without apps/settings/build-direct.sh)
#   fixed bar      (step 1b's review) an xdgact window of fixed size with the plugin's titlebar: listed in "fixed"; its zoom
#                  light drawn disabled (captured under the pointer) and a click there leaves its box and mode; a resizable
#                  window's light still zooms (the control)
#   fixed keys     (step 1b's review) Super+Alt+F and Super+Ctrl+F leave that window (bindings.lua asks the plugin's
#                  window_size, which refuses it, logged); the control zooms with Super+Alt+F and back
#   move-to      on another output when there is one: a tiled window takes the same place there (still tiled, that
#                  output's Desktop) and back; a Free window keeps its size and lands on that output (skipped with one
#                  output)
#   move-invalid   move_to an unknown output or the window's own: the `tiling` notice says "invalid", nothing moves
#   covered        (integrator review of 4ead6fb) no "enter" while an Exclusive layer is mapped elsewhere on the output or
#                  while a layer covers the light; after each, the pointer moved off and back gives "enter" again. The layer
#                  is a tiny Quickshell config written into the run directory. Locked (integrator nested rerun of 25e757c,
#                  D24): a hover before the lock, its popover closed with Esc (the shell's own lock closes it; the foreign
#                  locker does not), then no "enter" while the session is locked, the pointer moved off and back onto the
#                  light meanwhile; once unlocked, "enter" comes by itself, the pointer resting on the light.
# The locked case above also calls move_to when the plugin has it (TL34): nothing moves.
# Both locked cases release the fixture through unlock_session, which checks that Hyprland itself reports the session
# unlocked (`hyprctl locked`) before the next case (integrator nested pass of ab485fb: a locker killed before its unlock landed
# would leave the session locked for every later case). A failed C1 log check prints the plugin's own lines for the victim,
# Hyprland's lock state and the layers on GF-REF.
# Step 4a (docs/specs/tiling.md TL27, TL28; only with tiling-layouts and tile-hover; the second foot window and a third,
# closed after the cases). The plugin is driven directly: no shell surface is involved (the shell only shows a suggestion
# after its own arrangement):
#   zone           arrange({layout:"thirds", windows:[first], zone:2}): the first window alone in the right third, no group;
#                  the reply's suggestion belongs to that `placed` notice and offers zones 0 and 1 (frames inside the
#                  work area) with the other windows, never the first
#   pick           arrange({…, windows:[second], zone:0, with:first}): the left third, in the first's group; the suggestion
#                  now offers zone 1
#   pick-held      a pick into a zone the layout holds is refused (reason invalid): nothing moves, the suggestion stays
#   stale          any other change of the records (Return to Previous Size of the second window) ends it (null)
#   suggest-off    (step 5, TL32) a zone placement's suggestion ends when config tilingSuggestions turns false and does not
#                  come back when it turns true; while false, a zone placement posts placed and the reply has no
#                  suggestion; true again, the same placement has one
#   minimized      the third window minimized by the plugin from GF-REF is offered after a new zone placement of the first;
#                  a pick brings it back to GF-REF's Desktop into the middle third, in the first's group (D27)
#   fit wide       (D69, after the step 4c cases) an xdgact window wider than a quarter: its open event's unfitZones lists the
#                  quarters and the left and right halves, not the top half (an ordinary window's lists none); a quarter and
#                  Quarters asked by it are refused (nothing moves), the top half places it; Quarters asked by an ordinary
#                  window leaves it out and its quarters share rows and columns; the reply's unfitZones lists it
# Step 4b (docs/specs/tiling.md TL29; only with tiling-groups; right after the step 4a cases, whose first and third windows
# end in one group):
#   group-front    the second window (no group) focused above the group; group_front(first): the third window, then the
#                  first, come above it (Hyprland's stacking order, `clients` bottom first); the focus stays on the second
#   no-group       group_front of the second window changes nothing in the stacking order
#   invalid        group_front of an unknown window: the `tiling` notice says "invalid"
#   zoomed         the first window zoomed, then full screen, and focused (its tile suspended): group_front(first) leaves it
#                  above the third (integrator review of cd74af2)
#   locked         while the foreign locker holds the session lock, group_front raises nothing (reason "locked")
# Step 4c (docs/specs/tiling.md TL30; only with tiling-shared-edge; right after the step 4b cases, the third and first
# windows still one group in the middle and right thirds):
#   shared-edge    the pointer on the middle of their shared edge (in the margin), pressed and dragged 60 px right: the
#                  third window grows, the first follows with the gap kept, both stay tiled in one group, the plugin posts
#                  `resized`; dragged back, both are where they were
#   covered        a foot that reports the mouse centred on the handle, then zoomed, then full screen: each time the drag
#                  over the handle reaches foot (it reads mouse reports) and moves neither window (the frontmost window
#                  under the pointer gets the click)
#   minimum        dragged to the output's right side: the edge stops at the right window's minimum (at least Hyprland's
#                  20 px floor), the gap and its right side kept; then back
#   locked         while the foreign locker holds the session lock the same drag moves nothing
#   after unlock   0.5 s after the unlock, with no other motion first, the handle's drag moves the edge (the first press
#                  after unlocking is the user's), then back
#   lock mid-drag  the button held, 30 px, the lock, 60 px more, the release: the windows keep the frames of before the lock,
#                  both Tiled in one group after the unlock; then back
#   outside        in the margin 20 px below the surface tops (outside the handle), the pointer settled on the wallpaper
#                  first: the drag is Hyprland's resize of one window, only one of the two boxes changes (Hyprland's lock
#                  state, the cursor, the active window and the layers are logged before the press)
# Step 6c (docs/specs/tiling.md TL33, ADR-0036 D64-D67; with the shell, after the full-screen popover rounds):
#   reveal         a window in full screen: the Dock on the overlay layer, the menu bar away; the pointer at the top edge:
#                  the plugin posts titlebar-reveal true and the menu bar comes into view, stays while the pointer is on
#                  the titlebar, and leaves with it (titlebar-reveal false, the bar hidden)
#   green-popover  the revealed zoom light's popover open, a click on the light leaves full screen and closes it (no overlay
#                  left, the Dock back on the top layer); off full screen the same click under tile_popover's popover zooms
#   split-green    (integrator review of 7096305, MAJOR 1) a Split View member's light lies under the menu bar's strip: clicked
#                  under its open popover it leaves the Split View, no app menu opens, no overlay stays
# Step 6e (TL33, ADR-0036 D73-D75; with tiling-split-titles; the step 6a-6d Split View cases read a member's box without a
# band, drag it by its revealed bar and click its revealed green light):
#   split-titles   the pointer at the top edge over the left half reveals the left member's bar alone (the plugin's numbered
#                  log line names it, read in Hyprland's in-memory log) and titlebar-reveal comes; moving across within the band
#                  brings the right member's bar and the left one goes; below the band it goes too (titlebar-reveal false);
#                  coming from below reveals nothing; the band walked across the gap between the halves in 4 px steps: the left
#                  bar stays in the gap and goes only when the right one comes (review of #99); the session locked during the
#                  revealed bar's drag: back in its half at the lock, no swap at the release; a member moved off by a key, or
#                  back from special:minimized, has its titlebar in reach (below the work area's top)
# Step 6d (TL33, ADR-0036 D71; with tiling-split-rows):
#   split-rows     unsplit with an unknown `how` refused; Replace Tiled Window: the member home, the Split View Desktop shown,
#                  the other kept in its half and waiting, the suggestion never offering the window replaced, a pick filling the
#                  half; Make Window Full Screen: home in full screen, the other filling; Replace with one member refused; Replace
#                  refused while locked
#   replace-shell  (with the shell) Replace Tiled Window from a member's popover by the keys: the picker shows on the Split
#                  View Desktop and a Return picks the first window offered
#   overview-drop  (with the shell; step 6e, the follow-up of #78) the Overview's own drop path (dev hook overview dropProbe)
#                  refuses a window dropped on a Split View Desktop (one the picker left on its Desktop) and a member dropped
#                  on another Desktop; nothing moves
#   gather         (without the shell too) a headless output made, the window placed on its area with GF-REF's Desktop kept,
#                  the output removed: the plugin logs it and centres it across GF-REF's work area; again while the foreign
#                  locker holds the lock: it stays off every output until the unlock, then comes back (review of 7096305)
# Gate C1 (integrator re-reviews of 439e1f2 and 20b62e3; always run, last): a window that UNMAPS while the plugin's titlebar
# drag holds it, the window object alive (its Desktop and layout space are gone: Window.cpp:750, :2639). A closed window is
# no test: Hyprland unmaps and frees it in one step and the titlebar's destructor drops the drag. The victim is
# tests/tools/xdgact, which on SIGUSR2 attaches a null buffer (what an app that closes to the tray does). Each case starts a
# drag past the threshold, unmaps the victim, and then:
#   moving-focused     the pointer moves on, then the release (the victim kept the focus: its unmap releases the held buttons)
#   moving-unfocused   the other window took the focus first (the unmap keeps the held button: the plugin's drag goes on)
#   still-focused      no motion after the unmap, then the release
#   still-unfocused    the focus moved first, no motion after the unmap, then the release
#   shared-edge        (with tiling-shared-edge) the victim one of two windows arranged left and right, unmapped while the
#                      plugin drags their shared edge: it leaves the drag (logged) but still bounds it: the other follows,
#                      dragged far toward the victim it stops at the victim's minimum, inside the work area; Tiled again
# With them (tiling-shared-edge; xdgact windows), not C1 cases: the left one of two xdgact windows arranged left and right
# opens an xdg popup over the handle; the drag there reaches the popup and moves neither window (TL30, D35). And an X11
# override-redirect menu (tests/tools/x11menu, on the nested Hyprland's own X display) over the handle, the left window
# focused: the plugin does not take the press (the right window keeps its box).
# Hyprland must answer after each, the plugin must log its guarded path ("closed or unmapped"), and coredumpctl must list no
# new Hyprland core dump. A/B against an older build (the integrator's proof that the cases reach the crash):
#   tests/compositor/tiling.sh --c1 --plugin /path/to/439e1f2/grassfield-compositor.so   (expected: FAIL, Hyprland gone)
#   tests/compositor/tiling.sh --c1                                                     (this tree's build: PASS)
# --c1 runs only the gate C1 cases; --plugin PATH unloads compositor/build/grassfield-compositor.so, loads PATH for the run
# and loads the tree's build again at the end (a different path is a different library even if the first stays mapped,
# FR23). Use a fresh nested session for each side of the A/B: a crash ends the session.
# Expected boxes come from the output's reserved area read right before each placement (the plugin reads it at placement,
# TL1: the shell's menu bar and Dock may claim their zones after the run starts). A failed check prints the plugin's
# [grassfield] WARN and ERR lines logged since the previous check. The plugin verbs are called directly (they return a
# no-op dispatcher), never through a Lua function that returns nothing.
# Usage (bare command, nested session of this tree running with the plugin loaded): tests/compositor/tiling.sh
# Logs and captures: .dev/tiling/run-<timestamp>/.
set -uo pipefail

root=$(git -C "$(dirname "$0")" rev-parse --show-toplevel)
c1_only=0 plugin_path=""
default_plugin=$root/compositor/build/grassfield-compositor.so
while [[ $# -gt 0 ]]; do
  case $1 in
    --c1) c1_only=1 ;;
    --plugin) plugin_path=${2:?--plugin needs a path}; shift ;;
    *) echo "usage: tests/compositor/tiling.sh [--c1] [--plugin PATH]" >&2; exit 2 ;;
  esac
  shift
done
dev=$root/.dev
out=GF-REF
# shellcheck source=../../scripts/dev/pidfile.sh
. "$root/scripts/dev/pidfile.sh"
# shellcheck source=titlebar_geometry.sh
. "$root/tests/compositor/titlebar_geometry.sh" || exit 2
dev_nested_target "$dev" || exit 2
sock=$DEV_NESTED_SOCK
bus=$(cat "$dev/bus.address" 2>/dev/null || true)

run=$dev/tiling/run-$(date +%Y%m%d-%H%M%S)
mkdir -p "$run"
log=$run/run.log
say() { printf '%s %s\n' "$(date '+%H:%M:%S.%3N')" "$*" | tee -a "$log"; }
nestctl() { timeout 10 "$root/scripts/nestctl" "$@"; }
pointer() { timeout 30 "$root/scripts/dev/pointer.sh" output "$out" "$@" >>"$log" 2>&1; }
fail=0
hyprlog=${XDG_RUNTIME_DIR:-/run/user/$(id -u)}/hypr/$DEV_NESTED_SIG/hyprland.log
log_lines() { grep -ac "" "$hyprlog" 2>/dev/null || echo 0; }
# The plugin logged a line matching PATTERN: Hyprland's in-memory log (`hyprctl rollinglog`) or its log file, polled for up to
# 3 s (the file is buffered: a line can reach it seconds late; integrator nested pass of 6355acb). Use a pattern that names the
# window (its address) so that an earlier case's line never matches. No pipe into grep -q (pipefail: SIGPIPE).
plugin_logged() { # pattern
  local _ log
  for _ in $(seq 1 15); do
    log=$(nestctl rollinglog 2>/dev/null)
    grep -aq -- "$1" <<<"$log" && return 0
    grep -aq -- "$1" "$hyprlog" 2>/dev/null && return 0
    sleep 0.2
  done
  return 1
}
log_mark=$(log_lines)
plugin_warnings() {
  local l
  tail -n +"$((log_mark + 1))" "$hyprlog" 2>/dev/null | grep -a '\[grassfield\]' | grep -aE 'WARN|ERR' | tail -n 5 | while IFS= read -r l; do say "  plugin: $l"; done
}
check() {
  local name=$1
  shift
  if "$@"; then say "PASS: $name"; else say "FAIL: $name"; plugin_warnings; fail=1; fi
  log_mark=$(log_lines)
}

swapped=0
restore_plugin() {
  ((swapped)) || return 0
  nestctl plugin unload "$plugin_path" >>"$log" 2>&1
  nestctl plugin load "$default_plugin" >>"$log" 2>&1
  swapped=0
}
if [[ -n $plugin_path ]]; then
  [[ -f $plugin_path ]] || { say "setup error: no plugin at $plugin_path"; exit 2; }
  nestctl plugin unload "$default_plugin" >>"$log" 2>&1
  nestctl plugin load "$plugin_path" >>"$log" 2>&1 || { say "setup error: could not load $plugin_path"; nestctl plugin load "$default_plugin" >>"$log" 2>&1; exit 2; }
  swapped=1
  trap restore_plugin EXIT
  say "plugin for this run: $plugin_path"
  sleep 1
fi
if ((c1_only)); then
  nestctl -j grassfield >/dev/null 2>&1 || say "note: no grassfield plugin answers: the C1 cases then exercise Hyprland alone"
else
  nestctl -j grassfield 2>/dev/null | jq -e '.features | index("window-tiling")' >/dev/null 2>&1 || { say "SKIP: the plugin does not advertise window-tiling (load this tree's plugin)"; exit 2; }
fi

# A settled session before the first case (at most 20 s): the shell's menu bar mapped on GF-REF, and GF-REF's reserved
# area and active Desktop unchanged for 1 s. Started right after nested-up, the run read the free area before the shell
# reserved its zones and found GF-REF on another Desktop than the window (integrator nested pass of 426a676). The Dock is
# not waited for: with two outputs it lives on the one whose edge the pointer last reached.
settle_state() { nestctl monitors -j | jq -r --arg o "$out" '.[] | select(.name == $o) | "reserved \(.reserved) desktop \(.activeWorkspace.id)"'; }
menubar_on_out() { nestctl layers -j 2>/dev/null | jq -e --arg o "$out" '[.[$o] | .. | objects | select(.namespace? == "grassfield-menubar")] | length > 0' >/dev/null 2>&1; }
prev="" same=0 bar=0
for _ in $(seq 1 80); do
  menubar_on_out && bar=1
  cur=$(settle_state)
  if [[ $cur == "$prev" ]]; then same=$((same + 1)); else same=0; prev=$cur; fi
  ((bar && same >= 4)) && break
  sleep 0.25
done
((bar)) && say "settled: the menu bar is mapped on $out, its reserved area and Desktop stable (${prev:-?})" ||
  say "note: no menu bar on $out after 20 s (no shell?): running without it"

read -r mx my mw mh rtop rbottom < <(nestctl monitors -j | jq -r --arg o "$out" '.[] | select(.name == $o) | "\(.x) \(.y) \(.width) \(.height) \(.reserved[1]) \(.reserved[3])"')
# Free area of any output: "x y w h" (reserved = [left, top, right, bottom]).
area_of() { nestctl monitors -j | jq -r --arg o "$1" '.[] | select(.name == $o) | "\(.x + .reserved[0]) \(.y + .reserved[1]) \(.width - .reserved[0] - .reserved[2]) \(.height - .reserved[1] - .reserved[3])"'; }
# The window ADDRESS out of zoom and full screen, whatever it is in (Hyprland's fullscreen: 0 none, 1 zoom, 2 full screen):
# true once it is in neither. A case that leaves it zoomed would fail the next with "Window is fullscreen" (integrator
# re-review of 67800eb, C).
fs_clear() { # address
  local st
  st=$(nestctl clients -j | jq -r --arg a "$1" '.[] | select(.address == $a) | .fullscreen')
  case "$st" in
    1) nestctl dispatch "hl.dsp.window.fullscreen({ mode = \"maximized\", window = \"address:$1\" })" >>"$log" 2>&1; sleep 0.8 ;;
    2) nestctl dispatch "hl.dsp.window.fullscreen({ mode = \"fullscreen\", window = \"address:$1\" })" >>"$log" 2>&1; sleep 0.8 ;;
  esac
  st=$(nestctl clients -j | jq -r --arg a "$1" '.[] | select(.address == $a) | .fullscreen')
  [[ $st == 0 || -z $st ]]
}
# Grassfield's Zoom of the window ADDRESS (ADR-0036 D78, Zoom is Fill): with the plugin's zoom-fill, filled as a tile
# (fullscreen 0, its record placed "fill"); without it Hyprland's maximized mode (fullscreen 1).
zoom_fill_on() { nestctl -j grassfield 2>/dev/null | jq -e '.features | index("zoom-fill")' >/dev/null 2>&1; }
fill_place() { nestctl grassfield-tiling 2>/dev/null | jq -r --arg a "${1#0x}" '[.outputs[].windows[] | select(.address == $a)][0].place // "none"'; }
zoomed() { # address
  local st place
  st=$(nestctl clients -j | jq -r --arg a "$1" '.[] | select(.address == $a) | .fullscreen')
  if zoom_fill_on; then
    place=$(fill_place "$1")
    say "  zoom of $1: fullscreen $st, tile record $place (want 0 and fill: Zoom is Fill)"
    [[ $st == 0 && $place == fill ]]
  else
    say "  zoom of $1: fullscreen $st (want 1)"
    [[ $st == 1 ]]
  fi
}
# The window ADDRESS out of its zoom, whichever it is (a filled window back to its box from before; out of the maximized
# mode); true once it is neither.
unzoom() { # address
  nestctl dispatch "hl.plugin.grassfield.tile(\"$1\", \"previous\")" >>"$log" 2>&1
  sleep 0.8
  fs_clear "$1" && [[ $(fill_place "$1") != fill ]]
}
# Another output that touches GF-REF's left (or right) edge over an overlapping span: its name, or "".
neighbour_on() { # left|right
  nestctl monitors -j | jq -r --arg o "$out" --arg side "$1" --argjson x "$mx" --argjson w "$mw" --argjson y "$my" --argjson h "$mh" \
    '[.[] | select(.name != $o and .y < ($y + $h) and (.y + .height) > $y
       and (if $side == "left" then (.x + .width) == $x else .x == ($x + $w) end)) | .name][0] // ""'
}

pids=()
locker_pid=""
foreign=$root/tests/security/foreign_locker/ForeignLocker.qml
foreign_ipc() { WAYLAND_DISPLAY=$sock HYPRLAND_INSTANCE_SIGNATURE=$DEV_NESTED_SIG timeout 5 qs ipc -p "$foreign" call foreign "$@" 2>/dev/null; }
# Hyprland's own session-lock state ("true" | "false"): what the plugin reads at each motion (CSessionLockManager).
hypr_locked() { nestctl locked 2>/dev/null | tr -d '[:space:]'; }
# The foreign locker fixture (tests/security/foreign_locker) takes the session lock; true once it holds it (secure).
lock_session() {
  WAYLAND_DISPLAY=$sock HYPRLAND_INSTANCE_SIGNATURE=$DEV_NESTED_SIG GRASSFIELD_FOREIGN_LOCKER=1 DBUS_SESSION_BUS_ADDRESS="${bus:-disabled:}" \
    setsid "$root/scripts/dev/isolated.sh" --name tiling-locker "$root/tests/security/foreign_locker/run.sh" --no-color >>"$run/locker.log" 2>&1 </dev/null &
  locker_pid=$!
  locked=""
  local _
  for _ in $(seq 1 60); do
    locked=$(foreign_ipc status)
    [[ $locked == "locked secure" ]] && return 0
    sleep 0.1
  done
  return 1
}
# Releases it and waits until Hyprland itself reports the session unlocked (integrator nested pass of ab485fb): the unlock
# is asked again while Hyprland still says locked (a `qs ipc` call can time out under load), and the process is killed only
# once Hyprland is unlocked or every attempt failed (a locker killed while it holds the lock leaves Hyprland's dead-locker
# state: the session stays locked and every later case would fail for that reason). True when Hyprland is unlocked.
unlock_session() {
  local _ __
  for _ in $(seq 1 10); do
    foreign_ipc unlock >/dev/null
    for __ in $(seq 1 10); do
      [[ $(hypr_locked) == false ]] && break 2
      sleep 0.1
    done
  done
  for _ in $(seq 1 30); do kill -0 "$locker_pid" 2>/dev/null || break; sleep 0.1; done
  kill -0 "$locker_pid" 2>/dev/null && kill "$locker_pid" 2>/dev/null
  locker_pid=""
  say "  hyprctl locked: $(hypr_locked)"
  [[ $(hypr_locked) == false ]]
}
# What may hold the pointer or the keyboard now, for a failed check: Hyprland's session lock and the layers mapped on GF-REF.
surfaces_state() {
  say "  hyprctl locked: $(hypr_locked); layers on $out: $(nestctl layers -j 2>/dev/null | jq -r --arg o "$out" '[.[$o].levels // {} | .[][] | .namespace] | join(",")' 2>/dev/null)"
}
# A shell popup is open on GF-REF: the shell maps its overlay layer only then (shell/overlay/Overlay.qml), over the whole
# output, so a press there closes the popup and reaches no window.
shell_popup_open() {
  nestctl layers -j 2>/dev/null | jq -e --arg o "$out" '[.[$o].levels // {} | .[][] | select(.namespace == "grassfield-overlay")] | length > 0' >/dev/null 2>&1
}
# Closes a shell popup left open on GF-REF (Esc goes to the popup, which holds the keyboard) and says so: a press of the next
# case would only close it (integrator nested pass of 2765002: the overlay was mapped at each failed C1 check).
close_shell_popup() { # case name
  shell_popup_open || return 0
  say "  $1: a shell popup was open on $out (the overlay is mapped): closed with Esc before the case"
  # An Esc sent while the popup is still opening reaches no popup (the overlay maps, then takes the keyboard; measured under load
  # 35: an Esc 20 ms after the open was lost and the popover, opened by tile_popover, stayed 16 s): sent again until it closes.
  local try
  for try in 1 2 3 4; do
    "$root/scripts/dev/keys.sh" -k Escape >>"$log" 2>&1
    wait_popup_closed 30 && return 0
  done
  say "  $1: the popup is still open after Esc"
  return 0
}
# The nested shell answers its IPC (tests/visual/ipc.sh): its popups open and close asynchronously. Asked once.
shell_running=""
shell_up() {
  if [[ -z $shell_running ]]; then
    local k
    if k=$(timeout 5 "$root/tests/visual/ipc.sh" menubar openKind 2>/dev/null) && [[ $k != refused ]]; then shell_running=1; else shell_running=0; fi
  fi
  [[ $shell_running == 1 ]]
}
# Waits (up to 5 s) until no shell popup shows on GF-REF: no grassfield-overlay layer mapped and, when the shell answers, its
# open popup kind empty. A fixed wait after Esc raced the overlay's unmap under load: the next click reached the closing popup
# (integrator nested pass of 12e3dd3).
# An IPC call that fails or times out (the shell busy under load) says nothing: it is not "no popup" (PR #70 review: openKind ''
# was such a timeout while the overlay showed a real popover). Argument: how many polls (default 50; 100 ms apart, longer when the
# IPC times out).
wait_popup_closed() {
  local k="" n=${1:-50} rc t0=$SECONDS
  for _ in $(seq 1 "$n"); do
    if ! shell_popup_open; then
      shell_up || return 0
      k=$(timeout 3 "$root/tests/visual/ipc.sh" menubar openKind 2>/dev/null)
      rc=$?
      [[ $rc == 0 && -z $k ]] && return 0
      [[ $rc != 0 ]] && k="(no answer)"
    fi
    sleep 0.1
  done
  say "  a shell popup still showed after $((SECONDS - t0)) s (openKind '${k}')"
  return 1
}
# Waits (up to 3 s, with the shell running) until a popup shows on GF-REF (the popover a tile_popover asked for).
wait_popup_open() {
  shell_up || return 0
  for _ in $(seq 1 30); do
    shell_popup_open && return 0
    sleep 0.1
  done
  return 1
}
# The binding loops the shell has logged so far (.dev/shell.log; the gate Q2 counts one as a failure).
shell_loops() {
  local n
  n=$(grep -ac "Binding loop" "$dev/shell.log" 2>/dev/null)
  echo "${n:-0}"
}
# The plugin's last lines naming PATTERN (Hyprland's in-memory log, then its file), for a failed check.
plugin_lines() { # pattern
  local lines l
  lines=$( { nestctl rollinglog 2>/dev/null; tail -n 3000 "$hyprlog" 2>/dev/null; } | grep -a '\[grassfield\]' | grep -a -- "$1" | tail -n 5)
  if [[ -z $lines ]]; then
    say "  plugin: no line names $1"
  else
    while IFS= read -r l; do say "  plugin: $l"; done <<<"$lines"
  fi
}
cleanup() {
  if [[ -n $locker_pid ]] && kill -0 "$locker_pid" 2>/dev/null; then
    foreign_ipc unlock >/dev/null # never leave the nested session locked
    sleep 0.5
    kill "$locker_pid" 2>/dev/null
  fi
  for p in "${pids[@]}"; do kill "$p" 2>/dev/null; done
  nestctl output remove GF-GATHER >/dev/null 2>&1 || true # the gather case's output, if it was left behind
  restore_plugin
}
trap cleanup EXIT

alive() { nestctl version -j >/dev/null 2>&1; }

# ---- gate C1: a window that unmaps (alive) during the plugin's titlebar drag (see the header) ----
dumps() { coredumpctl --no-legend --no-pager list 2>/dev/null | grep -ci hyprland || true; }
xdg_addr="" xdg_pid=""
open_xdg() { # app id [min width]: an xdgact window on GF-REF; its address in xdg_addr, its pid in xdg_pid
  setsid "$root/scripts/dev/isolated.sh" "$root/tests/tools/xdgact/xdgact.sh" "$@" >>"$run/xdgact.out" 2>&1 </dev/null &
  pids+=("$!")
  xdg_addr="" xdg_pid=""
  for _ in $(seq 1 50); do
    read -r xdg_addr xdg_pid < <(nestctl clients -j | jq -r --arg c "$1" '[.[] | select(.class == $c)][0] | select(. != null) | "\(.address) \(.pid)"')
    [[ -n $xdg_addr ]] && break
    sleep 0.2
  done
  [[ -n $xdg_addr ]] && nestctl dispatch "hl.dsp.window.move({ x = $((mx + 400)), y = $((my + 300)), window = 'address:$xdg_addr' })" >>"$log" 2>&1
  sleep 0.8
}
grip_of() { # address: the middle of its titlebar relative to GF-REF, "px py"
  nestctl clients -j | jq -r --arg a "$1" --argjson mx "$mx" --argjson my "$my" --argjson mid "$GF_TB_MID" \
    '.[] | select(.address == $a) | "\((.at[0] + .size[0] / 2 - $mx) | floor) \((.at[1] - $mid - $my) | floor)"'
}
c1_other=""
run_c1() { # name focused|unfocused moving|still
  local name=$1 focus=$2 motion=$3 px py p
  close_shell_popup "C1 $name"
  open_xdg "gf-c1-$name"
  if [[ -z $xdg_addr ]] || ! read -r px py < <(grip_of "$xdg_addr"); then
    check "C1 $name: the victim window opened" false
    return
  fi
  if [[ $motion == moving ]]; then
    pointer abs "$px" "$py" down sleep 150 drag $((px + 40)) "$py" sleep 2200 drag $((px + 120)) $((py + 30)) sleep 150 drag $((px + 160)) $((py + 40)) sleep 300 up &
  else
    pointer abs "$px" "$py" down sleep 150 drag $((px + 40)) "$py" sleep 2200 up &
  fi
  p=$!
  sleep 0.8
  if [[ $focus == unfocused ]]; then
    nestctl dispatch "hl.dsp.focus({ window = 'address:$c1_other' })" >>"$log" 2>&1
    sleep 0.3
  fi
  kill -USR2 "$xdg_pid" 2>/dev/null
  wait "$p"
  sleep 0.8
  check "C1 $name: the dragged window unmapped (alive) during the drag ($focus, $motion): Hyprland alive" alive
  c1_guarded() { # on a failure, the plugin's own lines for the victim and what may have held the pointer
    plugin_logged "${xdg_addr#0x} closed or unmapped" && return 0
    plugin_lines "${xdg_addr#0x}"
    plugin_lines "held back" # the request log budget (20 lines, then 1 per second) dropped lines when this names any
    surfaces_state
    return 1
  }
  check "C1 $name: the plugin reached its guarded path (\"${xdg_addr#0x} closed or unmapped\") and moved nothing" c1_guarded
  kill "$xdg_pid" 2>/dev/null
  sleep 0.3
}
# The shared edge's drag (TL30, integrator review of a6d04df): the victim and the other xdgact window arranged left and
# right (one group), the handle dragged 40 px, the victim unmapped (alive) with the button held, then dragged far left, past
# the victim, and released. Hyprland answers, the plugin logs that the victim left the drag (8965f85's guard: setTargetGeom
# never reaches its missing space), the other window followed but stopped where the victim's minimum (20 px, its frame from
# the press) puts the edge: a window that leaves the drag still bounds it (integrator re-review of ce82fd3: without it the
# other window went off the work area), and it is Tiled again (the drag ended: its one `resized`).
run_c1_edge() {
  local tb=$GF_TB_HEIGHT lx ly lw lh rx rw rx1 rw1 hx hy p
  close_shell_popup "C1 shared-edge"
  open_xdg gf-c1-edge
  if [[ -z $xdg_addr || -z $c1_other ]]; then
    check "C1 shared-edge: the victim window opened" false
    return
  fi
  nestctl dispatch "hl.plugin.grassfield.arrange('{\"layout\":\"left-right\",\"windows\":[\"$xdg_addr\",\"$c1_other\"]}')" >>"$log" 2>&1
  sleep 0.8
  read -r lx ly lw lh < <(nestctl clients -j | jq -r --arg a "$xdg_addr" '.[] | select(.address == $a) | "\(.at[0]) \(.at[1]) \(.size[0]) \(.size[1])"')
  read -r rx rw < <(nestctl clients -j | jq -r --arg a "$c1_other" '.[] | select(.address == $a) | "\(.at[0]) \(.size[0])"')
  if [[ -z ${lx:-} || -z ${rx:-} ]] || ((rx <= lx + lw)); then
    check "C1 shared-edge: the two windows are arranged left and right (${lx:-?}+${lw:-?}, ${rx:-?})" false
    kill "$xdg_pid" 2>/dev/null
    return
  fi
  hx=$((lx + lw + (rx - lx - lw) / 2 - mx)) hy=$((ly - tb + (lh + tb) / 2 - my))
  pointer abs "$hx" "$hy" sleep 300 down drag $((hx + 40)) "$hy" sleep 2200 drag 2 "$hy" sleep 300 up &
  p=$!
  sleep 1.2
  kill -USR2 "$xdg_pid" 2>/dev/null
  wait "$p"
  sleep 0.8
  check "C1 shared-edge: the victim unmapped (alive) during the edge's drag: Hyprland alive" alive
  c1_edge_guarded() {
    plugin_logged "window ${xdg_addr#0x} closed, unmapped or no longer resizing" && return 0
    plugin_lines "${xdg_addr#0x}"
    plugin_lines "held back"
    surfaces_state
    return 1
  }
  check "C1 shared-edge: the plugin logged that the victim left the drag" c1_edge_guarded
  read -r rx1 rw1 < <(nestctl clients -j | jq -r --arg a "$c1_other" '.[] | select(.address == $a) | "\(.at[0]) \(.size[0])"')
  local stop=$((lx + 20 + rx - lx - lw)) # the victim's left side + its 20 px floor + the gap
  say "  the other window ${rw1:-?} px wide at ${rx1:-?} (was $rw at $rx; the victim's minimum puts its left side at $stop)"
  check "C1 shared-edge: dragged past the gone victim, the other window stops at the victim's minimum, its right side kept" \
    test $((${rx1:-0} - stop)) -ge -1 -a $((${rx1:-0} - stop)) -le 1 -a $((${rx1:-0} + ${rw1:-0} - rx - rw)) -ge -1 -a $((${rx1:-0} + ${rw1:-0} - rx - rw)) -le 1
  c1_edge_tiled() {
    local st
    st=$(nestctl grassfield-tiling 2>>"$log" | jq -r --arg a "${c1_other#0x}" '[.outputs[].windows[] | select(.address == $a)][0].state // "none"')
    say "  the other window's record: $st"
    [[ $st == tiled ]]
  }
  check "C1 shared-edge: the other window is Tiled again (the drag ended)" c1_edge_tiled
  kill "$xdg_pid" 2>/dev/null
  sleep 0.3
}
# A popup in front of the handle keeps the click from it (TL30, ADR-0036 D35; integrator re-review of ce82fd3 and nested pass
# of 3d56d60): two xdgact windows arranged left and right, the left one opens an xdg popup on the middle of its right edge
# (SIGHUP), over the handle.
#   frontmost  the left window raised first (a popup opens from a click in its window): the drag there reaches the popup
#              (xdgact prints "popup pressed") and moves neither window
#   below      the right window raised over it, the popup still there: the plugin does not take the press (the left window
#              keeps its box: the edge's drag would widen it); Hyprland's own routing gives the press to the right window's
#              border grab area, which its windowAt finds before the lower window's popup (as without the plugin): logged
run_edge_popup() {
  local tb=$GF_TB_HEIGHT a b apid bpid lx ly lw lh rx rw l1 r1 hx hy mark
  close_shell_popup "shared-edge popup"
  open_xdg gf-edge-popup-a
  a=$xdg_addr apid=$xdg_pid
  open_xdg gf-edge-popup-b
  b=$xdg_addr bpid=$xdg_pid
  if [[ -z $a || -z $b ]]; then
    check "shared-edge popup: the two xdgact windows opened" false
    kill "$apid" "$bpid" 2>/dev/null
    return
  fi
  nestctl dispatch "hl.plugin.grassfield.arrange('{\"layout\":\"left-right\",\"windows\":[\"$a\",\"$b\"]}')" >>"$log" 2>&1
  sleep 0.8
  read -r lx ly lw lh < <(nestctl clients -j | jq -r --arg a "$a" '.[] | select(.address == $a) | "\(.at[0]) \(.at[1]) \(.size[0]) \(.size[1])"')
  read -r rx rw < <(nestctl clients -j | jq -r --arg a "$b" '.[] | select(.address == $a) | "\(.at[0]) \(.size[0])"')
  if [[ -z ${lx:-} || -z ${rx:-} ]] || ((rx <= lx + lw)); then
    check "shared-edge popup: the two windows are arranged left and right (${lx:-?}+${lw:-?}, ${rx:-?})" false
    kill "$apid" "$bpid" 2>/dev/null
    return
  fi
  hx=$((lx + lw + (rx - lx - lw) / 2 - mx)) hy=$((ly - tb + (lh + tb) / 2 - my))
  nestctl dispatch "hl.dsp.window.alter_zorder({ mode = 'top', window = 'address:$a' })" >>"$log" 2>&1
  sleep 0.3
  mark=$(grep -ac "" "$run/xdgact.out" 2>/dev/null || echo 0)
  kill -HUP "$apid" 2>/dev/null
  popup_line() { tail -n +"$((mark + 1))" "$run/xdgact.out" 2>/dev/null | grep -aq -- "$1"; }
  for _ in $(seq 1 30); do popup_line "popup mapped gf-edge-popup-a" && break; sleep 0.1; done
  check "shared-edge popup: the left window's popup is mapped" popup_line "popup mapped gf-edge-popup-a"
  sleep 0.3
  pointer abs 20 $((mh / 2)) sleep 200 abs "$hx" "$hy" sleep 300 down drag $((hx + 60)) "$hy" sleep 200 up sleep 400
  for _ in $(seq 1 20); do popup_line "popup pressed gf-edge-popup-a" && break; sleep 0.1; done
  check "shared-edge popup frontmost: the popup in front of the handle gets the press" popup_line "popup pressed gf-edge-popup-a"
  read -r l1 < <(nestctl clients -j | jq -r --arg a "$a" '.[] | select(.address == $a) | "\(.at[0]) \(.at[1]) \(.size[0]) \(.size[1])"')
  read -r r1 < <(nestctl clients -j | jq -r --arg a "$b" '.[] | select(.address == $a) | "\(.at[0]) \(.size[0])"')
  say "  left window $l1 (was $lx $ly $lw $lh), right window $r1 (was $rx $rw)"
  check "shared-edge popup frontmost: neither window moved" test "$l1" = "$lx $ly $lw $lh" -a "$r1" = "$rx $rw"
  # The right window over the left one, the popup still mapped: no window's box but the right one's grab area holds the point.
  nestctl dispatch "hl.dsp.window.alter_zorder({ mode = 'top', window = 'address:$b' })" >>"$log" 2>&1
  sleep 0.3
  mark=$(grep -ac "" "$run/xdgact.out" 2>/dev/null || echo 0)
  pointer abs 20 $((mh / 2)) sleep 200 abs "$hx" "$hy" sleep 300 down drag $((hx + 60)) "$hy" sleep 200 up sleep 600
  read -r l1 < <(nestctl clients -j | jq -r --arg a "$a" '.[] | select(.address == $a) | "\(.at[0]) \(.at[1]) \(.size[0]) \(.size[1])"')
  read -r r1 < <(nestctl clients -j | jq -r --arg a "$b" '.[] | select(.address == $a) | "\(.at[0]) \(.size[0])"')
  say "  popup below: left window $l1 (was $lx $ly $lw $lh), right window $r1 (was $rx $rw; Hyprland's own border resize may move it)," \
    "the popup $(popup_line "popup pressed gf-edge-popup-a" && echo pressed || echo "not pressed"), $(popup_line "popup done" && echo dismissed || echo "still mapped")"
  check "shared-edge popup below: the plugin does not take the press (the left window keeps its box)" test "$l1" = "$lx $ly $lw $lh"
  kill "$apid" "$bpid" 2>/dev/null
  sleep 0.3
}
# An X11 menu over the handle keeps the press from it (TL30, D35; integrator review of 0c4c8f2): two xdgact windows arranged
# left and right, the left one focused (for an override-redirect window that wants no focus Hyprland's windowAt returns the
# focused window: an edge window, as when the menu is that window's own), and an X11 override-redirect window of type popup
# menu (tests/tools/x11menu) over the handle. The plugin does not take the press: the right window keeps its box (the edge's
# drag would move its left side). Hyprland's own routing may then resize the focused left window by its border, as it does
# without the plugin: logged. Skipped when the nested Hyprland has no X display.
run_edge_x11menu() {
  local tb=$GF_TB_HEIGHT a b apid bpid mpid lx ly lw lh rx rw r1 l1 hx hy xdisplay menu
  nestctl dispatch "hl.dsp.exec_cmd('printf %s \"\$DISPLAY\" > $run/xdisplay')" >>"$log" 2>&1
  sleep 0.8
  xdisplay=$(cat "$run/xdisplay" 2>/dev/null || true)
  if [[ ! $xdisplay =~ ^:[0-9]+$ || $xdisplay == "${DISPLAY:-}" ]]; then
    say "SKIP: shared-edge X11 menu (the nested Hyprland has no X display of its own: '${xdisplay}')"
    return
  fi
  "$root/tests/tools/x11menu/x11menu.sh" --build >>"$log" 2>&1 || { check "shared-edge X11 menu: tests/tools/x11menu builds" false; return; }
  close_shell_popup "shared-edge X11 menu"
  open_xdg gf-edge-x11-a
  a=$xdg_addr apid=$xdg_pid
  open_xdg gf-edge-x11-b
  b=$xdg_addr bpid=$xdg_pid
  if [[ -z $a || -z $b ]]; then
    check "shared-edge X11 menu: the two xdgact windows opened" false
    kill "$apid" "$bpid" 2>/dev/null
    return
  fi
  nestctl dispatch "hl.plugin.grassfield.arrange('{\"layout\":\"left-right\",\"windows\":[\"$a\",\"$b\"]}')" >>"$log" 2>&1
  sleep 0.8
  read -r lx ly lw lh < <(nestctl clients -j | jq -r --arg a "$a" '.[] | select(.address == $a) | "\(.at[0]) \(.at[1]) \(.size[0]) \(.size[1])"')
  read -r rx rw < <(nestctl clients -j | jq -r --arg a "$b" '.[] | select(.address == $a) | "\(.at[0]) \(.size[0])"')
  if [[ -z ${lx:-} || -z ${rx:-} ]] || ((rx <= lx + lw)); then
    check "shared-edge X11 menu: the two windows are arranged left and right (${lx:-?}+${lw:-?}, ${rx:-?})" false
    kill "$apid" "$bpid" 2>/dev/null
    return
  fi
  hx=$((lx + lw + (rx - lx - lw) / 2 - mx)) hy=$((ly - tb + (lh + tb) / 2 - my))
  nestctl dispatch "hl.dsp.focus({ window = 'address:$a' })" >>"$log" 2>&1
  sleep 0.3
  : >"$run/x11menu.out"
  setsid "$root/scripts/dev/isolated.sh" "$root/tests/tools/x11menu/x11menu.sh" "$xdisplay" $((mx + hx - 100)) $((my + hy - 60)) 200 120 \
    >"$run/x11menu.out" 2>&1 </dev/null &
  mpid=$!
  pids+=("$mpid")
  for _ in $(seq 1 30); do grep -aq mapped "$run/x11menu.out" && break; sleep 0.1; done
  check "shared-edge X11 menu: the override-redirect window is mapped" grep -aq mapped "$run/x11menu.out"
  sleep 0.5
  menu=$(nestctl clients -j | jq -r '[.[] | select(.xwayland == true and .size == [200, 120])][0] | select(. != null) | "\(.at[0]) \(.at[1])"')
  say "  the X11 menu at ${menu:-?} (wanted $((mx + hx - 100)) $((my + hy - 60))), the handle at $((mx + hx)),$((my + hy))"
  pointer abs 20 $((mh / 2)) sleep 200 abs "$hx" "$hy" sleep 300 down drag $((hx + 60)) "$hy" sleep 200 up sleep 600
  read -r l1 < <(nestctl clients -j | jq -r --arg a "$a" '.[] | select(.address == $a) | "\(.at[0]) \(.at[1]) \(.size[0]) \(.size[1])"')
  read -r r1 < <(nestctl clients -j | jq -r --arg a "$b" '.[] | select(.address == $a) | "\(.at[0]) \(.size[0])"')
  say "  left window $l1 (was $lx $ly $lw $lh; Hyprland's own border resize may change it), right window $r1 (was $rx $rw), the menu" \
    "$(grep -aq pressed "$run/x11menu.out" && echo pressed || echo "not pressed")"
  check "shared-edge X11 menu: the plugin does not take the press (the right window keeps its box)" test "$r1" = "$rx $rw"
  kill "$mpid" "$apid" "$bpid" 2>/dev/null
  sleep 0.3
}
c1_cases() {
  "$root/tests/tools/xdgact/xdgact.sh" --build >>"$log" 2>&1 || { check "C1: tests/tools/xdgact builds" false; return; }
  local dumps0 dumps1
  dumps0=$(dumps)
  open_xdg gf-c1-other
  c1_other=$xdg_addr
  run_c1 moving-focused focused moving
  run_c1 moving-unfocused unfocused moving
  run_c1 still-focused focused still
  run_c1 still-unfocused unfocused still
  if nestctl -j grassfield 2>/dev/null | jq -e '.features | index("tiling-shared-edge")' >/dev/null 2>&1; then
    run_c1_edge
    run_edge_popup
    run_edge_x11menu
  else
    say "SKIP: C1 shared-edge and the popup over the handle (the plugin does not advertise tiling-shared-edge)"
  fi
  if command -v coredumpctl >/dev/null 2>&1; then
    dumps1=$(dumps)
    check "C1: no new Hyprland core dump (coredumpctl: $dumps0 before, $dumps1 after)" test "$dumps1" -le "$dumps0"
  else
    say "SKIP: coredumpctl is not available: the core dump check is left to the integrator"
  fi
}
if ((c1_only)); then
  c1_cases
  check "Hyprland alive" alive
  exit $fail
fi
env -u DISPLAY WAYLAND_DISPLAY="$sock" DBUS_SESSION_BUS_ADDRESS="$bus" setsid "$root/scripts/dev/isolated.sh" --name tiling \
  foot -T tiling-foot -w 800x500 sh -c 'exec sleep 100000' >>"$run/foot.out" 2>&1 </dev/null &
pids+=("$!")

geometry() { nestctl clients -j | jq -r '[.[] | select(.title == "tiling-foot")][0] | select(. != null) | "\(.at[0]) \(.at[1]) \(.size[0]) \(.size[1]) \(.address)"'; }
for _ in $(seq 1 100); do [[ -n $(geometry) ]] && break; sleep 0.2; done
sleep 1
read -r x0 y0 w0 h0 addr < <(geometry)
[[ -n ${addr:-} ]] || { say "setup error: no foot window"; exit 2; }
# The window may open on the other output: put it on GF-REF.
nestctl dispatch "hl.dsp.window.move({ x = $((mx + 300)), y = $((my + 200)), window = 'address:$addr' })" >>"$log" 2>&1
sleep 0.8
read -r x0 y0 w0 h0 addr < <(geometry)
say "foot ${w0}x${h0} at $x0,$y0 ($addr)"

# Free area and the expected boxes (core/Tiling.cpp: margin 8 around and between, titlebar above each surface), read
# once the session settled: right after nested-up the menu bar may not reserve its strip yet.
m=8 tb=$GF_TB_HEIGHT
# The free area of GF-REF now and the boxes derived from it; called right before each placement.
area_now() {
  read -r ax ay aw ah < <(area_of "$out")
  halfw=$(((aw - 3 * m) / 2)) halfh=$(((ah - 3 * m) / 2))
  ry=$((ay + m + tb)) fullh=$((ah - 2 * m - tb))
  rx=$((ax + 2 * m + halfw))
  case ${side:-} in
    right) tx=$rx ;;
    left) tx=$((ax + m)) ;;
  esac
}
area_now
say "GF-REF ${mw}x${mh} at $mx,$my, free area ${aw}x${ah} at $ax,$ay, titlebar $tb"

# drag WHERE_X WHERE_Y [hold-capture-name hold-place] (layout coordinates): press on the titlebar's middle, glide to the
# point, release there. pointer.sh takes coordinates relative to GF-REF. With a capture name, the capture is taken once the
# plugin logged that the preview of HOLD-PLACE shows for this window (it waits for the preview delay since tiling step 2,
# TL17; integrator nested pass of 412b42e: a capture taken at a fixed 1.6 s could precede it), one frame later.
drag() {
  local tx=$(($1 - mx)) ty=$(($2 - my)) shot=${3:-} place=${4:-} x y w h _a
  read -r x y w h _a < <(geometry)
  local px=$((x + w / 2 - mx)) py=$((y - GF_TB_MID - my))
  if [[ -n $shot ]]; then
    pointer abs "$px" "$py" down sleep 150 drag $(((px + tx) / 2)) $(((py + ty) / 2)) sleep 150 drag "$tx" "$ty" sleep 2500 up &
    local p=$!
    if ! plugin_logged "tiling preview ${addr#0x}: $place on "; then
      say "  no \"tiling preview ${addr#0x}: $place\" line within 3 s: the capture is taken anyway"
    fi
    sleep 0.3
    "$root/scripts/dev/shot.sh" "$shot" "$out" >>"$log" 2>&1 && cp "$dev/shots/$shot.png" "$run/" 2>/dev/null
    wait "$p"
  else
    pointer abs "$px" "$py" down sleep 150 drag $(((px + tx) / 2)) $(((py + ty) / 2)) sleep 150 drag "$tx" "$ty" sleep 400 up
  fi
  sleep 0.8
}
is_box() { # x y w h (surface), 1 px slack
  local x y w h _a
  read -r x y w h _a < <(geometry)
  say "  foot ${w}x${h} at $x,$y (want ${3}x${4} at $1,$2)"
  (( x - $1 <= 1 && $1 - x <= 1 && y - $2 <= 1 && $2 - y <= 1 && w - $3 <= 1 && $3 - w <= 1 && h - $4 <= 1 && $4 - h <= 1 ))
}
size_is() { local _x _y w h _a; read -r _x _y w h _a < <(geometry); say "  foot ${w}x${h} (want ${1}x${2})"; (( w == $1 && h == $2 )); }

left_n=$(neighbour_on left) right_n=$(neighbour_on right)
say "layout: left edge ${left_n:-free}, right edge ${right_n:-free}"
# The edge the tiling cases use (free), and the one the shared-edge case uses (another output there).
if [[ -z $right_n ]]; then
  side=right edge_x=$((mx + mw - 1))
elif [[ -z $left_n ]]; then
  side=left edge_x=$mx
else
  say "SKIP: both edges of $out are shared ($left_n, $right_n): no free edge to tile at"
  exit 2
fi
shared_side="" shared_x="" neighbour=""
if [[ -n $left_n ]]; then shared_side=left shared_x=$mx neighbour=$left_n; fi
if [[ -n $right_n ]]; then shared_side=right shared_x=$((mx + mw - 1)) neighbour=$right_n; fi
# x of a box of width W (output px from GF-REF's left) on the free side: the right-side value, mirrored for the left side.
sidex() { if [[ $side == right ]]; then echo "$1"; else echo $((mw - $1 - $2)); fi; }
# preview (owner decision D-8): the frame is the blurred material, not alpha only. A pattern window (black text on white)
# lies behind the right half; the detail of a crop of it (grey standard deviation) seen through the preview must fall
# far below what an alpha-only pane leaves (a pane at the tint's opacity keeps about 1 - alpha = 55 % of it; Hyprland's
# blur keeps almost none). The crop (output px) is inside the preview, beside the dragged window (which hangs over the
# edge from the pointer), over the pattern; both are mirrored when the free edge is the left one.
env -u DISPLAY WAYLAND_DISPLAY="$sock" DBUS_SESSION_BUS_ADDRESS="$bus" setsid "$root/scripts/dev/isolated.sh" --name tiling \
  foot -T tiling-pattern -w 760x600 -o colors-dark.background=ffffff -o colors-light.background=ffffff \
  -o colors-dark.foreground=000000 -o colors-light.foreground=000000 -o colors-dark.alpha=1 -o colors-light.alpha=1 \
  sh -c 'i=0; while [ $i -lt 60 ]; do echo "MWMW#### |||| ==== MWMW#### |||| ==== MWMW#### ||||"; i=$((i + 1)); done; printf "\033[?25l"; exec sleep 100000' \
  >>"$run/foot.out" 2>&1 </dev/null &
pattern_pid=$!
pids+=("$pattern_pid")
pattern_addr=""
for _ in $(seq 1 50); do
  pattern_addr=$(nestctl clients -j | jq -r '[.[] | select(.title == "tiling-pattern")][0].address // ""')
  [[ -n $pattern_addr ]] && break
  sleep 0.2
done
crop_x=$(sidex 1150 300)
detail() { magick "$1" -crop "300x200+$crop_x+330" +repage -colorspace Gray -format '%[fx:int(standard_deviation*2550)/10]' info: 2>>"$log"; }
if [[ -n $pattern_addr ]]; then
  nestctl dispatch "hl.dsp.window.move({ x = $((mx + $(sidex 1100 760))), y = $((my + 300)), window = 'address:$pattern_addr' })" >>"$log" 2>&1
  nestctl dispatch "hl.dsp.focus({ window = 'address:$addr' })" >>"$log" 2>&1
  sleep 1
  "$root/scripts/dev/shot.sh" tiling-pattern-baseline "$out" >>"$log" 2>&1 && cp "$dev/shots/tiling-pattern-baseline.png" "$run/" 2>/dev/null
fi
area_now
drag "$edge_x" $((my + mh / 2)) "tiling-preview-$side" "$side"
if [[ -n $pattern_addr ]]; then
  d0=$(detail "$run/tiling-pattern-baseline.png")
  d1=$(detail "$run/tiling-preview-$side.png")
  check "preview: the windows behind the frame are blurred (detail ${d1:-?} under it, ${d0:-?} without it; under 30 %)" \
    awk -v a="${d1:-999}" -v b="${d0:-0}" 'BEGIN { exit !(b >= 20 && a < 0.3 * b) }'
else
  check "preview: the pattern window opened" false
fi
kill "$pattern_pid" 2>/dev/null
sleep 0.5
check "free-edge: released at the free $side edge, the window fills the $side half" is_box "$tx" "$ry" "$halfw" "$fullh"
drag $((mx + mw / 2)) $((my + mh / 2))
check "drag-out: dragged away from the tile, the window gets ${w0}x${h0} back" size_is "$w0" "$h0"
area_now
drag "$edge_x" $((my + 40))
check "top-corner: released at the top of the $side edge, the top-$side quarter" is_box "$tx" "$ry" "$halfw" $((halfh - tb))
drag $((mx + mw / 2)) $((my + mh / 2))
if [[ -n $shared_side ]]; then
  drag "$shared_x" $((my + mh / 2))
  read -r cx cy cw ch _ < <(geometry)
  say "  $shared_side edge shared with $neighbour: ${cw}x${ch} at $cx,$cy"
  check "shared-edge: the $shared_side edge touches $neighbour, no tiling (size kept)" test "$cw" -eq "$w0" -a "$ch" -eq "$h0"
  drag $((mx + mw / 2)) $((my + mh / 2))
else
  say "SKIP: shared-edge (no output touches $out)"
fi
area_now
drag $((mx + mw / 2)) $((my + 2)) tiling-preview-fill fill
check "menu-bar: released on the menu bar, the free area is filled" is_box $((ax + m)) "$ry" $((aw - 2 * m)) "$fullh"
drag $((mx + mw / 2)) $((my + mh / 2))
check "drag-out after fill: ${w0}x${h0} again" size_is "$w0" "$h0"

# The 1.0.0-rc6 report ("the gesture up to fill the screen is very slow"), two causes (docs/specs/tiling.md TL17):
# menu-bar-at-once: with no output above GF-REF the menu bar fills at once: a release 60 ms after the pointer reached it fills
#   (before, the preview waited 250 ms and such a release only moved the window up to the bar).
# drag-follows: the titlebar drag sets the window under the pointer at once (warpPositionSize, as Hyprland's own move with
#   animate_mouse_windowdragging off); before, each step restarted the 300 ms windowsMove animation and the window trailed the
#   pointer. A second pointer device jumps 400 px while the drag holds; the capture taken right after shows the plugin's strip
#   under the pointer and the wallpaper where the left part of the bar was.
above=$(nestctl monitors -j | jq -r --argjson x "$mx" --argjson w "$mw" --argjson y "$my" \
  '[.[] | select(((.y + .height / .scale) | round) == $y and .x < ($x + $w) and (.x + .width / .scale) > $x)] | length')
if [[ $above == 0 ]]; then
  area_now
  read -r x y w h _a < <(geometry)
  px=$((x + w / 2 - mx)) py=$((y - GF_TB_MID - my))
  pointer abs "$px" $((py + 3)) sleep 120 abs "$px" "$py" sleep 200 down sleep 150 drag "$px" $((py / 2)) sleep 60 drag "$px" 2 sleep 60 up
  sleep 0.8
  check "menu-bar-at-once: released 60 ms after reaching the menu bar (no output above), the free area is filled" is_box $((ax + m)) "$ry" $((aw - 2 * m)) "$fullh"
  drag $((mx + mw / 2)) $((my + mh / 2))
else
  say "SKIP: menu-bar-at-once (an output lies above $out: its menu bar keeps the delay)"
fi
read -r x y w h _a < <(geometry)
mscale=$(nestctl monitors -j | jq -r --arg o "$out" '.[] | select(.name == $o) | .scale')
gx=$((x + w / 2 - mx)) gy=$((y - GF_TB_MID - my)) jump=400
pointer abs "$gx" $((gy + 3)) sleep 120 abs "$gx" "$gy" sleep 200 down sleep 150 drag $((gx + 20)) "$gy" sleep 2500 up &
pfollow=$!
sleep 1.5
timeout 10 "$root/scripts/dev/pointer.sh" output "$out" abs $((gx + 20 + jump)) "$gy" >>"$log" 2>&1
WAYLAND_DISPLAY=$sock timeout 10 grim -o "$out" "$run/drag-follows.png" 2>>"$log"
wait "$pfollow"
sleep 0.6
follows=$(python3 -I - "$run/drag-follows.png" "$mscale" "$(jq -r '.titlebar.backgroundDark.value' "$root/ui/tokens/tokens.json")" \
  "$(jq -r '.titlebar.backgroundLight.value' "$root/ui/tokens/tokens.json")" $((x - mx)) $((y - GF_TB_HEIGHT + 4 - my)) "$w" $((20 + jump)) <<'PY' 2>>"$log"
import subprocess, sys
png, scale = sys.argv[1], float(sys.argv[2])
tokens = [tuple(int(t.lstrip("#")[i:i + 2], 16) for i in (0, 2, 4)) for t in sys.argv[3:5]]
x0, row, w, moved = (int(v) for v in sys.argv[5:9])
def px(x, y):
    out = subprocess.run(["magick", png, "-format", "%[hex:p{%d,%d}]" % (int(x * scale), int(y * scale)), "info:"], capture_output=True, text=True).stdout
    return tuple(int(out[i:i + 2], 16) for i in (0, 2, 4)) if len(out) >= 6 else None
def strip(p):
    return p is not None and any(max(abs(a - b) for a, b in zip(p, t)) <= 8 for t in tokens)
new = [strip(px(x0 + moved + w * f, row)) for f in (0.2, 0.4, 0.6, 0.8)]
old = [strip(px(x0 + moved * f, row)) for f in (0.15, 0.35, 0.55, 0.75)]
print("%d %d" % (all(new), not any(old)))
PY
)
say "  drag-follows: strip at the new place, wallpaper at the old: '$follows' (want '1 1'); capture $run/drag-follows.png"
check "drag-follows: right after a jump of the pointer the window is under it (no windowsMove animation during the drag)" test "$follows" = "1 1"
drag $((mx + mw / 2)) $((my + mh / 2))

area_now
nestctl dispatch "hl.plugin.grassfield.tile(\"$addr\", \"left\")" >>"$log" 2>&1
sleep 0.8
check "ipc: tile(address, \"left\") places the left half" is_box $((ax + m)) "$ry" "$halfw" "$fullh"
nestctl dispatch "hl.plugin.grassfield.tile(\"$addr\", \"previous\")" >>"$log" 2>&1
sleep 0.8
check "ipc: tile(address, \"previous\") gives ${w0}x${h0} back" size_is "$w0" "$h0"

# other-output: press near the titlebar's far end and drag to the shared edge, so that the window's middle is on the
# neighbouring output; the IPC tile must use that output (R13 finding 1).
# The nested WAYLAND-1 output is a window in the owner's session and can be resized at any time: the neighbour is checked
# again right before, and the step is skipped when the window's middle does not land on it.
neighbour=""
[[ -n $shared_side ]] && neighbour=$(neighbour_on "$shared_side")
nbox=$([[ -n $neighbour ]] && nestctl monitors -j | jq -r --arg o "$neighbour" '.[] | select(.name == $o) | "\(.x) \(.width)"')
if [[ -n $neighbour ]]; then
  read -r x y w h _a < <(geometry)
  if [[ $shared_side == left ]]; then
    pointer abs $((x + w - 40 - mx)) $((y - GF_TB_MID - my)) down sleep 150 drag 400 $((y - GF_TB_MID - my)) sleep 150 drag 2 $((y - GF_TB_MID - my)) sleep 400 up
  else
    pointer abs $((x + 40 - mx)) $((y - GF_TB_MID - my)) down sleep 150 drag $((mw - 400)) $((y - GF_TB_MID - my)) sleep 150 drag $((mw - 2)) $((y - GF_TB_MID - my)) sleep 400 up
  fi
  sleep 0.8
  read -r x y w h _a < <(geometry)
  read -r nbx nbw <<<"$nbox"
  say "  dragged over to $neighbour (${nbw} wide at x $nbx): ${w}x${h} at $x,$y (middle x $((x + w / 2)))"
  read -r nx ny nw nh < <(area_of "$neighbour")
fi
if [[ -n $neighbour ]] && (( x + w / 2 < nbx || x + w / 2 >= nbx + nbw )); then
  say "SKIP: other-output (the window's middle is not on $neighbour: the nested output changed size)"
  nestctl dispatch "hl.dsp.window.move({ x = $((mx + 300)), y = $((my + 200)), window = 'address:$addr' })" >>"$log" 2>&1
  sleep 0.8
elif [[ -n $neighbour ]]; then
  on_neighbour() {
    local mon want
    mon=$(nestctl clients -j | jq -r --arg a "$addr" '.[] | select(.address == $a) | .monitor')
    want=$(nestctl monitors -j | jq -r --arg o "$neighbour" '.[] | select(.name == $o) | .id')
    say "  monitor of the window: ${mon:-?} (want $neighbour, id ${want:-?})"
    [[ -n $mon && $mon == "$want" ]]
  }
  check "other-output: the window dropped on $neighbour belongs to its Desktop (as after Hyprland's own move)" on_neighbour
  nestctl dispatch "hl.plugin.grassfield.tile(\"$addr\", \"left\")" >>"$log" 2>&1
  sleep 0.8
  check "other-output: tile(address, \"left\") after a drag onto $neighbour places its left half there" is_box $((nx + m)) $((ny + m + tb)) $(((nw - 3 * m) / 2)) $((nh - 2 * m - tb))
  nestctl dispatch "hl.plugin.grassfield.tile(\"$addr\", \"previous\")" >>"$log" 2>&1
  sleep 0.8
  nestctl dispatch "hl.dsp.window.move({ x = $((mx + 300)), y = $((my + 200)), window = 'address:$addr' })" >>"$log" 2>&1
  sleep 0.8
else
  say "SKIP: other-output (no neighbouring output)"
fi

nestctl dispatch "hl.plugin.grassfield.config(\"tilingEdges\", \"false\")" >>"$log" 2>&1
drag "$edge_x" $((my + mh / 2))
check "options: with tilingEdges false the $side edge does not tile" size_is "$w0" "$h0"
nestctl dispatch "hl.plugin.grassfield.config(\"tilingEdges\", \"true\")" >>"$log" 2>&1

if nestctl -j grassfield 2>/dev/null | jq -e '.features | index("tiling-arrange")' >/dev/null 2>&1; then
  tiling_state() { nestctl grassfield-tiling 2>>"$log"; }
  state_has_output() {
    tiling_state | jq -e --arg o "$out" '.type == "tiling" and ([.outputs[] | select(.name == $o and .grid >= 1 and .area.w > 0)] | length == 1)' >/dev/null
  }
  check "state: hyprctl grassfield-tiling lists $out with its work area and grid" state_has_output

  env -u DISPLAY WAYLAND_DISPLAY="$sock" DBUS_SESSION_BUS_ADDRESS="$bus" setsid "$root/scripts/dev/isolated.sh" --name tiling \
    foot -T tiling-foot2 -w 700x450 sh -c 'exec sleep 100000' >>"$run/foot.out" 2>&1 </dev/null &
  pids+=("$!")
  geometry_of() { nestctl clients -j | jq -r --arg t "$1" '[.[] | select(.title == $t)][0] | select(. != null) | "\(.at[0]) \(.at[1]) \(.size[0]) \(.size[1]) \(.address)"'; }
  for _ in $(seq 1 100); do [[ -n $(geometry_of tiling-foot2) ]] && break; sleep 0.2; done
  sleep 1
  read -r _ _ _ _ addr2 < <(geometry_of tiling-foot2)
  if [[ -z ${addr2:-} ]]; then
    check "step 1: the second foot window opened" false
  else
    nestctl dispatch "hl.dsp.window.move({ x = $((mx + 500)), y = $((my + 300)), window = 'address:$addr2' })" >>"$log" 2>&1
    nestctl dispatch "hl.dsp.window.move({ x = $((mx + 300)), y = $((my + 200)), window = 'address:$addr' })" >>"$log" 2>&1
    nestctl dispatch "hl.dsp.focus({ window = 'address:$addr' })" >>"$log" 2>&1 # on top: the next in stacking order is foot2
    sleep 0.8
    read -r _ _ w2 h2 _ < <(geometry_of tiling-foot2)
    box_of() { # title x y w h (surface), 1 px slack
      local x y w h _a
      read -r x y w h _a < <(geometry_of "$1")
      say "  $1 ${w}x${h} at $x,$y (want ${4}x${5} at $2,$3)"
      (( x - $2 <= 1 && $2 - x <= 1 && y - $3 <= 1 && $3 - y <= 1 && w - $4 <= 1 && $4 - w <= 1 && h - $5 <= 1 && $5 - h <= 1 ))
    }
    record_is() { # address state ("none": no record)
      local got
      got=$(tiling_state | jq -r --arg a "${1#0x}" '[.outputs[].windows[] | select(.address == $a)][0].state // "none"')
      say "  record of $1: $got (want $2)"
      [[ $got == "$2" ]]
    }
    arrange() { nestctl dispatch "hl.plugin.grassfield.arrange('$1')" >>"$log" 2>&1; sleep 0.8; }
    tile_ipc() { nestctl dispatch "hl.plugin.grassfield.tile(\"$1\", \"$2\")" >>"$log" 2>&1; sleep 0.8; }
    to_ws() { nestctl dispatch "hl.dsp.window.move({ workspace = \"$2\", follow = false, window = \"address:$1\" })" >>"$log" 2>&1; sleep 0.8; }
    area_now
    arrange "{\"layout\":\"left-right\",\"windows\":[\"$addr\"]}"
    check "arrange: left-right from the first window, which takes the left half" box_of tiling-foot $((ax + m)) "$ry" "$halfw" "$fullh"
    check "arrange: the next window in stacking order fills the right half" box_of tiling-foot2 "$rx" "$ry" "$halfw" "$fullh"
    one_group() {
      tiling_state | jq -e --arg a "${addr#0x}" --arg b "${addr2#0x}" \
        '[.outputs[].windows[] | select(.address == $a or .address == $b)] | length == 2 and (map(.group) | unique | length == 1) and .[0].group > 0 and all(.layout == "left-right")' >/dev/null
    }
    check "arrange: both windows are one tile group in the state reply" one_group

    gen0=$(tiling_state | jq -r '.gen')
    arrange "{\"layout\":\"no-such-layout\",\"windows\":[\"$addr\"]}"
    gen1=$(tiling_state | jq -r '.gen')
    check "invalid: an unknown layout changes nothing (generation $gen0 -> $gen1)" test "$gen0" = "$gen1"
    check "invalid: the window keeps its tile" box_of tiling-foot $((ax + m)) "$ry" "$halfw" "$fullh"

    area_now
    nestctl dispatch "hl.plugin.grassfield.config(\"tilingMargins\", \"false\")" >>"$log" 2>&1
    sleep 0.8
    check "margins off: the arrangement is placed again without margins" box_of tiling-foot "$ax" $((ay + tb)) $((aw / 2)) $((ah - tb))
    nestctl dispatch "hl.plugin.grassfield.config(\"tilingMargins\", \"true\")" >>"$log" 2>&1
    sleep 0.8
    check "margins on: placed again with margins" box_of tiling-foot $((ax + m)) "$ry" "$halfw" "$fullh"

    nestctl dispatch "hl.dsp.window.fullscreen({ mode = \"fullscreen\", window = \"address:$addr\" })" >>"$log" 2>&1
    sleep 0.8
    check "full-screen: the tile is suspended" record_is "$addr" suspended
    nestctl dispatch "hl.dsp.window.fullscreen({ mode = \"fullscreen\", window = \"address:$addr\" })" >>"$log" 2>&1
    sleep 1
    check "full-screen: leaving it puts the window back in its tile" box_of tiling-foot $((ax + m)) "$ry" "$halfw" "$fullh"
    check "full-screen: tiled again" record_is "$addr" tiled

    ws2=$(nestctl clients -j | jq -r --arg a "$addr2" '.[] | select(.address == $a) | .workspace.name')
    to_ws "$addr2" special:minimized
    check "minimize: the tile is suspended" record_is "$addr2" suspended
    to_ws "$addr2" "$ws2"
    check "minimize: back on its Desktop, in its free zone" box_of tiling-foot2 "$rx" "$ry" "$halfw" "$fullh"
    check "minimize: tiled again" record_is "$addr2" tiled

    to_ws "$addr2" special:minimized
    tile_ipc "$addr" right
    to_ws "$addr2" "$ws2"
    size2() { local _x _y w h _a; read -r _x _y w h _a < <(geometry_of tiling-foot2); say "  tiling-foot2 ${w}x${h} (want ${w2}x${h2})"; (( w == w2 && h == h2 )); }
    check "zone-taken: its zone taken meanwhile, it comes back at its size from before" size2
    check "zone-taken: it is Free" record_is "$addr2" none
    tile_ipc "$addr" previous

    if lock_session; then
      read -r lx ly lw lh _ < <(geometry_of tiling-foot)
      gen_l0=$(tiling_state | jq -r '.gen')
      tile_ipc "$addr" left
      arrange "{\"layout\":\"quarters\",\"windows\":[\"$addr\"]}"
      # move_to (tiling step 3): refused before the output is even looked up.
      lock_other=$(nestctl monitors -j | jq -r --arg o "$out" '[.[] | select(.name != $o)][0].name // "NO-SUCH-OUTPUT"')
      nestctl dispatch "hl.plugin.grassfield.move_to(\"$addr\", \"$lock_other\")" >>"$log" 2>&1
      sleep 0.8
      gen_l1=$(tiling_state | jq -r '.gen')
      check "locked: tile, arrange and move_to move nothing while the session is locked" box_of tiling-foot "$lx" "$ly" "$lw" "$lh"
      check "locked: the records are unchanged (generation $gen_l0 -> $gen_l1)" test "$gen_l0" = "$gen_l1"
    else
      check "locked: the foreign locker holds the session lock (${locked:-no answer})" false
    fi
    check "locked: released, Hyprland reports the session unlocked" unlock_session
    sleep 0.5
  fi
else
  say "SKIP: step 1 cases (the plugin does not advertise tiling-arrange)"
fi

# ---- step 2: drags (see the header) ----
if nestctl -j grassfield 2>/dev/null | jq -e '.features | index("tiling-arrange")' >/dev/null 2>&1; then
  tiling_state() { nestctl grassfield-tiling 2>>"$log"; }
  record_field() { # address field ("none": no record)
    tiling_state | jq -r --arg a "${1#0x}" --arg f "$2" '[.outputs[].windows[] | select(.address == $a)][0][$f] // "none"'
  }
  record_is() { local got; got=$(record_field "$1" state); say "  record of $1: $got (want $2)"; [[ $got == "$2" ]]; }
  sides_are() { local got; got=$(record_field "$1" sides); say "  sides of $1: $got (want $2)"; [[ $got == "$2" ]]; }
  keys() { "$root/scripts/dev/keys.sh" "$@" >>"$log" 2>&1; }
  # A pointer gesture with a modifier held through it (keys.sh in the background): <wtype modifier> <hold ms> <pointer args>
  with_mod() {
    local mod=$1 ms=$2 k
    shift 2
    keys -M "$mod" -s "$ms" -m "$mod" &
    k=$!
    sleep 0.3
    pointer "$@"
    wait "$k" 2>/dev/null
    sleep 0.8
  }
  # Super+drag (Hyprland's move) from the window's middle to TO_X TO_Y (layout coordinates), held HOLD ms there.
  super_drag() { # to_x to_y hold_ms
    local x y w h _a fx fy tx=$(($1 - mx)) ty=$(($2 - my))
    read -r x y w h _a < <(geometry)
    fx=$((x + w / 2 - mx)) fy=$((y + h / 2 - my))
    with_mod logo $(($3 + 1800)) abs "$fx" "$fy" sleep 100 down sleep 150 drag $(((fx + tx) / 2)) $(((fy + ty) / 2)) sleep 150 drag "$tx" "$ty" sleep "$3" up
  }
  # The foot window Free at its size from before, at (300, 200) on GF-REF, focused; waits until it is there (the next case
  # reads its box: under load a fixed pause read the box before the move, integrator nested pass of ce82fd3).
  free_foot() {
    local _ x y _w _h _a
    nestctl dispatch "hl.plugin.grassfield.tile(\"$addr\", \"previous\")" >>"$log" 2>&1
    nestctl dispatch "hl.dsp.window.move({ x = $((mx + 300)), y = $((my + 200)), window = 'address:$addr' })" >>"$log" 2>&1
    nestctl dispatch "hl.dsp.focus({ window = 'address:$addr' })" >>"$log" 2>&1
    for _ in $(seq 1 30); do
      read -r x y _w _h _a < <(geometry)
      (( ${x:-0} - mx - 300 <= 1 && mx + 300 - ${x:-0} <= 1 && ${y:-0} - my - 200 <= 1 && my + 200 - ${y:-0} <= 1 )) && break
      sleep 0.1
    done
    sleep 0.3
  }
  # The foot window's box reaches X Y W H (surface, 1 px slack) within 3 s: a gesture's own result, not a fixed pause; is_box
  # logs the last look.
  box_reached() { # x y w h
    local _ x y w h _a
    for _ in $(seq 1 30); do
      read -r x y w h _a < <(geometry)
      (( x - $1 <= 1 && $1 - x <= 1 && y - $2 <= 1 && $2 - y <= 1 && w - $3 <= 1 && $3 - w <= 1 && h - $4 <= 1 && $4 - h <= 1 )) && break
      sleep 0.1
    done
    is_box "$@"
  }
  delay=$(jq -r '.tiling.previewDelay.value' "$root/ui/tokens/tokens.json")
  say "step 2: preview delay $delay ms (token tiling.previewDelay)"

  free_foot
  area_now
  super_drag "$edge_x" $((my + mh / 2)) $((delay + 400))
  check "super-drag: Hyprland's move released at the free $side edge after the delay tiles the $side half" is_box "$tx" "$ry" "$halfw" "$fullh"
  check "super-drag: the window has a tile record" record_is "$addr" tiled

  super_drag $((mx + mw / 2)) $((my + mh / 2)) 300
  check "super-out: Hyprland's move takes the tiled window out at its size from before (${w0}x${h0})" size_is "$w0" "$h0"
  grip_kept() {
    local x y w h _a px=$((mx + mw / 2)) py=$((my + mh / 2))
    read -r x y w h _a < <(geometry)
    say "  pointer at $px,$py; window ${w}x${h} at $x,$y"
    (( px - x - w / 2 <= 12 && x + w / 2 - px <= 12 && py > y && py < y + h ))
  }
  check "super-out: the grip stays under the pointer (the window's middle, as pressed on the tile)" grip_kept
  check "super-out: the window is Free" record_is "$addr" none

  free_foot
  super_drag "$edge_x" $((my + mh / 2)) 40
  check "delay: Hyprland's move released at the edge before the delay does not tile (${w0}x${h0} kept)" size_is "$w0" "$h0"
  # Back at (300, 200) first: Hyprland's move above left the window's middle on the edge, and a titlebar drag pressed there
  # rests on the place from the press (integrator nested pass of 412b42e).
  free_foot
  read -r x y w h _a < <(geometry)
  px=$((x + w / 2 - mx)) py=$((y - GF_TB_MID - my))
  pointer abs "$px" "$py" down sleep 150 drag $(((px + edge_x - mx) / 2)) $(((py + mh / 2) / 2)) sleep 150 drag $((edge_x - mx)) $((mh / 2)) sleep 40 up
  sleep 0.8
  check "delay: the titlebar drag released at the edge before the delay does not tile either" size_is "$w0" "$h0"

  free_foot
  area_now
  read -r x y w h _a < <(geometry)
  px=$((x + w / 2 - mx)) py=$((y - GF_TB_MID - my)) qx=$((ax - mx + aw * 2 / 5)) qy=$((ay - my + ah / 2))
  with_mod alt 2600 abs "$px" "$py" sleep 100 down sleep 150 drag $(((px + qx) / 2)) $(((py + qy) / 2)) sleep 150 drag "$qx" "$qy" sleep 100 up
  check "alt-drag: released in the middle with Alt held, at once, the left half (the pointer left of the middle)" is_box $((ax + m)) "$ry" "$halfw" "$fullh"

  free_foot
  area_now
  super_drag $((mx + mw / 2)) $((my + 2)) $((delay + 400))
  check "menu-bar-move: Hyprland's move released on the menu bar fills the free area (not the top clamp's box)" is_box $((ax + m)) "$ry" $((aw - 2 * m)) "$fullh"

  free_foot
  area_now
  read -r x y w h _a < <(geometry)
  bx=$((x + w + 3 - mx)) by=$((y + h / 2 - my)) # 3 px right of the surface: Hyprland's border grab (resize_on_border)
  pointer abs $((bx + 40)) "$by" sleep 150 abs "$bx" "$by" sleep 200 click sleep 120 click
  check "edge: a double-click on the right border extends the right side to the work area's edge" box_reached "$x" "$y" $((ax + aw - m - x)) "$h"
  check "edge: the window is tiled with its right side extended (sides \"right\")" sides_are "$addr" right

  free_foot
  area_now
  read -r x y w h _a < <(geometry)
  cx=$((x + w + 3 - mx)) cy=$((y + h + 3 - my))
  with_mod alt 2600 abs $((cx + 40)) $((cy + 40)) sleep 150 abs "$cx" "$cy" sleep 200 click sleep 120 click
  check "alt-corner: an Alt double-click on the bottom-right corner fills the work area" box_reached $((ax + m)) "$ry" $((aw - 2 * m)) "$fullh"
  free_foot

  if command -v chromium >/dev/null; then
    dead_proxy=127.0.0.1:9
    rm -rf "$run/chromium-profile"
    http_proxy=http://$dead_proxy https_proxy=http://$dead_proxy all_proxy=http://$dead_proxy no_proxy='' \
      env -u DISPLAY WAYLAND_DISPLAY="$sock" DBUS_SESSION_BUS_ADDRESS="$bus" GDK_BACKEND=wayland setsid "$root/scripts/dev/isolated.sh" --name tiling-chromium -- \
      chromium --user-data-dir="$run/chromium-profile" --no-first-run --no-default-browser-check --password-store=basic --disable-background-networking \
      --disable-component-update --disable-sync --proxy-server="$dead_proxy" --ozone-platform=wayland --window-size=1000,640 about:blank \
      >>"$run/chromium.out" 2>&1 </dev/null &
    pids+=("$!")
    chrome() { nestctl clients -j | jq -r '[.[] | select(.class == "chromium")][0] | select(. != null) | "\(.at[0]) \(.at[1]) \(.size[0]) \(.size[1]) \(.address)"'; }
    for _ in $(seq 1 80); do [[ -n $(chrome) ]] && break; sleep 0.25; done
    read -r _ _ _ _ caddr < <(chrome)
    if [[ -n ${caddr:-} ]]; then
      sleep 2
      nestctl dispatch "hl.dsp.window.move({ x = $((mx + 300)), y = $((my + 250)), window = 'address:$caddr' })" >>"$log" 2>&1
      sleep 0.8
      read -r cx0 cy0 cw0 ch0 _ < <(chrome)
      chrome_box() { # x y w h (client chrome: no titlebar band), 1 px slack
        local x y w h _a
        read -r x y w h _a < <(chrome)
        say "  chromium ${w}x${h} at $x,$y (want ${3}x${4} at $1,$2)"
        (( x - $1 <= 1 && $1 - x <= 1 && y - $2 <= 1 && $2 - y <= 1 && w - $3 <= 1 && $3 - w <= 1 && h - $4 <= 1 && $4 - h <= 1 ))
      }
      gx=$((cx0 + cw0 * 3 / 4 - mx)) gy=$((cy0 + 18 - my)) # empty tab strip
      pointer abs "$gx" $((gy + 3)) sleep 120 abs "$gx" "$gy" sleep 200 click sleep 700 # focus first
      area_now
      pointer abs "$gx" "$gy" sleep 200 down sleep 150 drag $(((gx + edge_x - mx) / 2)) "$gy" sleep 150 drag $((edge_x - mx)) $((mh / 2)) sleep 1800 up &
      p=$!
      sleep 1.4
      "$root/scripts/dev/shot.sh" tiling-chromium-preview "$out" >>"$log" 2>&1 && cp "$dev/shots/tiling-chromium-preview.png" "$run/" 2>/dev/null
      wait "$p"
      sleep 0.8
      check "chromium: dragged by its tab strip (Hyprland's move) to the free $side edge, the $side half" chrome_box "$tx" $((ay + m)) "$halfw" $((ah - 2 * m))
      read -r tcx tcy tcw _ _ < <(chrome)
      gx=$((tcx + tcw * 3 / 4 - mx)) gy=$((tcy + 18 - my))
      pointer abs "$gx" "$gy" sleep 200 down sleep 150 drag $((gx - 200)) $((gy + 150)) sleep 150 drag $((mw / 2)) $((mh / 2)) sleep 300 up
      sleep 0.8
      chrome_size() { local _x _y w h _a; read -r _x _y w h _a < <(chrome); say "  chromium ${w}x${h} (want ${cw0}x${ch0})"; (( w == cw0 && h == ch0 )); }
      check "chromium: dragged out by its tab strip, its size from before (the restarted move keeps the app's grab)" chrome_size
    else
      check "chromium: mapped" false
    fi
    pkill -f -- "--user-data-dir=$run/chromium-profile" 2>/dev/null
  else
    say "SKIP: chromium (not installed): the client-chrome drag case is NOT VERIFIED here"
  fi

  current_plugin=${plugin_path:-$default_plugin}
  free_foot
  read -r x y w h _a < <(geometry)
  fx=$((x + w / 2 - mx)) fy=$((y + h / 2 - my))
  keys -M logo -s 5200 -m logo &
  k=$!
  sleep 0.3
  pointer abs "$fx" "$fy" sleep 100 down sleep 150 drag $((fx + 100)) "$fy" sleep 2600 drag $((fx + 220)) "$fy" sleep 300 up &
  p=$!
  sleep 1.6
  nestctl plugin unload "$current_plugin" >>"$log" 2>&1
  wait "$p"
  wait "$k" 2>/dev/null
  sleep 0.8
  check "unload: Hyprland alive after the plugin unloaded in the middle of Hyprland's move" alive
  moved_on() { local x1 _y _w _h _a; read -r x1 _y _w _h _a < <(geometry); say "  x $x -> ${x1:-?} (want about +220)"; [[ -n ${x1:-} ]] && (( x1 - x >= 150 )); }
  check "unload: the drag went on as Hyprland's own" moved_on
  nestctl plugin load "$current_plugin" >>"$log" 2>&1
  sleep 1.5
  check "unload: loaded again, the plugin advertises window-tiling" bash -c "timeout 10 '$root/scripts/nestctl' -j grassfield 2>/dev/null | jq -e '.features | index(\"window-tiling\")' >/dev/null"
else
  say "SKIP: step 2 cases (the plugin does not advertise tiling-arrange)"
fi

# ---- step 3: the zoom light's popover and move_to (see the header) ----
if nestctl -j grassfield 2>/dev/null | jq -e '.features | index("tile-hover")' >/dev/null 2>&1; then
  events=$run/events.log
  socat -u UNIX-CONNECT:"${XDG_RUNTIME_DIR:-/run/user/$(id -u)}/hypr/$DEV_NESTED_SIG/.socket2.sock" STDOUT >"$events" 2>>"$log" </dev/null &
  pids+=("$!")
  sleep 0.3
  tiling_state() { nestctl grassfield-tiling 2>>"$log"; }
  record_is() { # address state ("none": no record)
    local got
    got=$(tiling_state | jq -r --arg a "${1#0x}" '[.outputs[].windows[] | select(.address == $a)][0].state // "none"')
    say "  record of $1: $got (want $2)"
    [[ $got == "$2" ]]
  }
  keys() { "$root/scripts/dev/keys.sh" "$@" >>"$log" 2>&1; }
  # The popover a tile_popover or a hover asked for is shown first (with the shell running), then Esc, then nothing shows
  # any more before the next case clicks (integrator nested pass of 12e3dd3: a fixed 0.5 s raced it).
  close_popover() {
    wait_popup_open || say "  no shell popover showed before Esc"
    keys -k Escape
    wait_popup_closed || true
  }
  move_to() { nestctl dispatch "hl.plugin.grassfield.move_to(\"$addr\", \"$1\")" >>"$log" 2>&1; sleep 0.8; }
  free_foot() {
    nestctl dispatch "hl.plugin.grassfield.tile(\"$addr\", \"previous\")" >>"$log" 2>&1
    nestctl dispatch "hl.dsp.window.move({ x = $((mx + 300)), y = $((my + 200)), window = 'address:$addr' })" >>"$log" 2>&1
    nestctl dispatch "hl.dsp.focus({ window = 'address:$addr' })" >>"$log" 2>&1
    sleep 0.8
  }
  ev_mark=0
  mark_events() { ev_mark=$(grep -ac "" "$events" 2>/dev/null || echo 0); }
  # The gfc/1 events (JSON, one per line) posted since mark_events that match the jq filter FILTER.
  events_since() { tail -n +"$((ev_mark + 1))" "$events" 2>/dev/null | sed -n 's/^grassfield>>//p' | jq -cR "fromjson? | select($1)" 2>/dev/null; }
  # The latest such event, waited for up to 3 s.
  event_came() { # filter
    local _ line
    for _ in $(seq 1 30); do
      line=$(events_since "$1" | tail -n 1)
      [[ -n $line ]] && { last_event=$line; return 0; }
      sleep 0.1
    done
    return 1
  }
  hover_filter() { echo ".type == \"tile-hover\" and .address == \"${addr#0x}\" and .state == \"$1\""; }
  hover_delay=$(jq -r '.tiling.hoverDelay.value' "$root/ui/tokens/tokens.json")
  say "step 3: hover delay $hover_delay ms (token tiling.hoverDelay)"

  free_foot
  mark_events
  nestctl dispatch "hl.plugin.grassfield.tile_popover(\"$addr\")" >>"$log" 2>&1
  last_event=""
  check "popover-verb: tile_popover posts tile-hover open for the window" event_came "$(hover_filter open)"
  open_event=$last_event
  say "  event: $open_event"
  light_on_bar() {
    local x y w h _a lx ly lw lh
    read -r x y w h _a < <(geometry)
    read -r lx ly lw lh < <(jq -r '"\(.x) \(.y) \(.w) \(.h)"' <<<"$open_event" 2>/dev/null)
    say "  light ${lw:-?}x${lh:-?} at ${lx:-?},${ly:-?}; surface at $x,$y, titlebar $tb"
    [[ -n ${lh:-} ]] && awk -v lx="$lx" -v ly="$ly" -v lw="$lw" -v lh="$lh" -v x="$x" -v y="$y" -v tb="$tb" \
      'BEGIN { cy = ly + lh / 2; exit !(lw > 0 && lh > 0 && lx >= x && lx + lw <= x + 120 && cy > y - tb && cy < y) }'
  }
  check "popover-verb: the light is the zoom light, at the left of the window's titlebar" light_on_bar
  check "popover-verb: the window can be tiled (tileable)" bash -c "jq -e '.tileable == true' <<<'$open_event' >/dev/null 2>&1"
  close_popover

  if [[ -n $open_event ]]; then
    read -r lcx lcy < <(jq -r '"\((.x + .w / 2) | floor) \((.y + .h / 2) | floor)"' <<<"$open_event")
    pointer abs $((lcx - mx + 200)) $((lcy - my + 150)) sleep 200
    mark_events
    pointer abs $((lcx - mx)) $((lcy - my)) sleep 300
    no_early_enter() { [[ -z $(events_since "$(hover_filter enter)") ]]; }
    check "hover: no enter before tiling.hoverDelay" no_early_enter
    sleep "$(awk -v d="$hover_delay" 'BEGIN { print (d + 500) / 1000 }')"
    check "hover: the pointer resting on the zoom light posts tile-hover enter" event_came "$(hover_filter enter)"
    check "hover: the enter carries the same light" bash -c "jq -e --argjson o '$open_event' '.x == \$o.x and .y == \$o.y' <<<'${last_event:-null}' >/dev/null 2>&1"
    pointer abs $((lcx - mx + 300)) $((lcy - my + 200)) sleep 300
    check "hover: leaving the light posts tile-hover leave" event_came "$(hover_filter leave)"
    sleep "$(awk -v d="$hover_delay" 'BEGIN { print (d + 300) / 1000 }')" # the shell's popover closes by itself
    close_popover
    # layouts-off: "Show layouts when hovering over the green button" off (TL32).
    nestctl dispatch "hl.plugin.grassfield.config(\"tilingLayouts\", \"false\")" >>"$log" 2>&1
    pointer abs $((lcx - mx + 200)) $((lcy - my + 150)) sleep 200
    mark_events
    pointer abs $((lcx - mx)) $((lcy - my)) sleep 300
    sleep "$(awk -v d="$hover_delay" 'BEGIN { print (d + 500) / 1000 }')"
    check "layouts-off: the pointer resting on the zoom light posts no enter" no_early_enter
    mark_events
    nestctl dispatch "hl.plugin.grassfield.tile_popover(\"$addr\")" >>"$log" 2>&1
    check "layouts-off: tile_popover still posts open" event_came "$(hover_filter open)"
    close_popover
    nestctl dispatch "hl.plugin.grassfield.config(\"tilingLayouts\", \"true\")" >>"$log" 2>&1
    pointer abs $((lcx - mx + 300)) $((lcy - my + 200)) sleep 300
  else
    check "hover: needs the light from the open event" false
  fi

  # fixed (ADR-0040 step 1b; integrator nested pass of 85c2c10, scenario 6): About This Computer (grassfield-settings
  # --about), a window of fixed size whose own zoom light is disabled. The reply lists it in "fixed"; tile_popover posts no
  # "open" for it; the pointer resting on its zoom light posts no "enter"; a click there posts nothing, opens no shell popup
  # and leaves its box. Its zoom light: the titlebar row of the "info" role (compositor/src/core/TitlebarLayout.cpp
  # appZoomLight: the third light, tokens window.*). Skipped without the Settings build (apps/settings/build-direct.sh).
  settings_bin=$dev/build/grassfield-settings
  if [[ -x $settings_bin ]]; then
    env -u DISPLAY WAYLAND_DISPLAY="$sock" DBUS_SESSION_BUS_ADDRESS="$bus" GRASSFIELD_SETTINGS_QML="$root/apps/settings/qml" \
      QML_IMPORT_PATH="$root/ui:$dev/build/qml" setsid "$root/scripts/dev/isolated.sh" --name tiling-about -- "$settings_bin" --about \
      >>"$run/about.out" 2>&1 </dev/null &
    pids+=("$!")
    about_box() { nestctl clients -j | jq -r '[.[] | select(.class == "org.grassfield.Settings" and .xdgTag == "info")][0] | select(. != null) | "\(.at[0]) \(.at[1]) \(.size[0]) \(.size[1]) \(.fullscreen) \(.address)"'; }
    for _ in $(seq 1 60); do [[ -n $(about_box) ]] && break; sleep 0.25; done
    read -r _ _ _ _ _ about < <(about_box)
    if [[ -n ${about:-} ]]; then
      nestctl dispatch "hl.dsp.window.move({ x = $((mx + 300)), y = $((my + 200)), window = 'address:$about' })" >>"$log" 2>&1
      nestctl dispatch "hl.dsp.focus({ window = 'address:$about' })" >>"$log" 2>&1
      sleep 0.8
      read -r ax0 ay0 aw0 ah0 afs0 _ < <(about_box)
      say "  About This Computer: $about, ${aw0}x${ah0} at $ax0,$ay0, fullscreen $afs0"
      about_events() { events_since ".type == \"tile-hover\" and .address == \"${about#0x}\""; }
      about_listed() { tiling_state | jq -e --arg a "${about#0x}" '(.fixed // []) | index($a) != null' >/dev/null 2>&1; }
      no_popup() { ! shell_popup_open; }
      check "fixed: the reply lists About This Computer among the windows of fixed size" about_listed
      mark_events
      nestctl dispatch "hl.plugin.grassfield.tile_popover(\"$about\")" >>"$log" 2>&1
      sleep 1.5
      check "fixed: tile_popover posts no tile-hover for it" test -z "$(about_events)"
      check "fixed: the plugin says why (fixed size)" plugin_logged "tile_popover: refused: window ${about#0x} is of fixed size"
      check "fixed: no shell popup opens from tile_popover" no_popup
      read -r zx zy < <(jq -r '.window | "\(.titlebarLightInset.value + 2 * (.lightDiameter.value + .lightGap.value) + .lightDiameter.value / 2 | floor) \(.titlebarHeight.value / 2 | floor)"' "$root/ui/tokens/tokens.json")
      lzx=$((ax0 + zx - mx)) lzy=$((ay0 + zy - my))
      pointer abs $((lzx + 200)) $((lzy + 150)) sleep 200
      mark_events
      pointer abs "$lzx" "$lzy" sleep 300
      sleep "$(awk -v d="$hover_delay" 'BEGIN { print (d + 500) / 1000 }')"
      check "fixed: the pointer resting on its disabled zoom light posts no tile-hover" test -z "$(about_events)"
      check "fixed: no shell popup opens from the hover" no_popup
      mark_events
      pointer click sleep 800
      check "fixed: a click on its disabled zoom light posts no tile-hover" test -z "$(about_events)"
      check "fixed: no shell popup opens from the click" no_popup
      read -r ax1 ay1 aw1 ah1 afs1 _ < <(about_box)
      say "  after the click: ${aw1:-?}x${ah1:-?} at ${ax1:-?},${ay1:-?}, fullscreen ${afs1:-?}"
      check "fixed: the click leaves its box (not zoomed, not tiled)" test "$ax1 $ay1 $aw1 $ah1 $afs1" = "$ax0 $ay0 $aw0 $ah0 $afs0"
      close_shell_popup "fixed"
      pointer abs $((lzx + 300)) $((lzy + 200)) sleep 200
      nestctl dispatch "hl.dsp.window.close({ window = 'address:$about' })" >>"$log" 2>&1
      sleep 0.5
    else
      check "fixed: About This Computer maps (grassfield-settings --about)" false
    fi
  else
    say "SKIP: fixed (no Settings build at $settings_bin: apps/settings/build-direct.sh)"
  fi

  # fixed bar (ADR-0040 step 1b's review): a window of fixed size drawn with the plugin's own titlebar (an xdgact window of
  # 420x300, minimum = maximum): its zoom light is disabled (drawn grey with no glyph under the pointer: captured) and a click
  # there leaves its box and its mode; a resizable window's click still zooms (the control).
  close_shell_popup "fixed bar" # a popup left by the case before would take the clicks below (review of D69, MINOR 3)
  open_xdg gf-fixed-bar 420x300
  if [[ -n $xdg_addr ]]; then
    fixed_addr=$xdg_addr fixed_pid=$xdg_pid
    mode_box() { nestctl clients -j | jq -r --arg a "$1" '.[] | select(.address == $a) | "\(.at[0]) \(.at[1]) \(.size[0]) \(.size[1]) \(.fullscreen)"'; }
    zoom_light_of() { # address: the middle of the plugin titlebar's zoom light, relative to GF-REF
      local x y
      read -r x y _ < <(mode_box "$1")
      echo "$((x + zl - mx)) $((y - GF_TB_MID - my))"
    }
    zl=$(jq -r '.window | .titlebarLightInset.value + 2 * (.lightDiameter.value + .lightGap.value) + .lightDiameter.value / 2 | floor' "$root/ui/tokens/tokens.json")
    nestctl dispatch "hl.dsp.focus({ window = 'address:$fixed_addr' })" >>"$log" 2>&1
    sleep 0.5
    fb0=$(mode_box "$fixed_addr")
    say "  fixed bar: $fixed_addr $fb0"
    fixed_listed() { tiling_state | jq -e --arg a "${fixed_addr#0x}" '(.fixed // []) | index($a) != null' >/dev/null 2>&1; }
    check "fixed bar: the reply lists the window among those of fixed size" fixed_listed
    close_shell_popup "fixed bar"
    read -r fzx fzy < <(zoom_light_of "$fixed_addr")
    pointer abs $((fzx + 120)) $((fzy + 80)) sleep 200 abs "$fzx" "$fzy" sleep 400
    "$root/scripts/dev/shot.sh" tiling-fixed-bar-light "$out" >>"$log" 2>&1 && cp "$dev/shots/tiling-fixed-bar-light.png" "$run/" 2>/dev/null
    pointer click sleep 800
    check "fixed bar: a click on its disabled zoom light leaves its box and mode (was $fb0)" test "$(mode_box "$fixed_addr")" = "$fb0"
    check "fixed bar: the plugin says why" plugin_logged "titlebar zoom: refused for a window of fixed size"
    close_shell_popup "fixed bar"
    # The control: a resizable window's zoom light still zooms (Fill since ADR-0036 D78), and back.
    unzoom "$addr" >/dev/null # untiled first: a filled window's zoom brings back its box instead
    nestctl dispatch "hl.dsp.focus({ window = 'address:$addr' })" >>"$log" 2>&1
    sleep 0.5
    read -r czx czy < <(zoom_light_of "$addr")
    pointer abs "$czx" "$czy" sleep 300 click sleep 800
    check "fixed bar: the control's zoom light zooms it" zoomed "$addr"
    check "fixed bar: the control is back from its zoom" unzoom "$addr"
    pointer abs 20 $((mh / 2)) sleep 200
    close_shell_popup "fixed bar"
    # fixed keys (step 1b's review: Super+Alt+F zoomed About to 1918x980, Super+Ctrl+F made it full screen): bindings.lua asks
    # the plugin's window_size, which refuses a window of fixed size; the control still zooms with Super+Alt+F, and back.
    # The chords go through tests/tools/vkbd (keysyms, the last one tapped with the others held), as tests/visual/flow-lib.sh
    # fl_chord does: wtype's modifiers reach apps but never Hyprland's binds, and a modifier wtype leaves held turns the next
    # Escape into Super+Alt+Escape (a first run of this case left Force Quit open over every later case).
    chord() {
      local args=() mods=() k last=$# i=0
      for k in "$@"; do
        i=$((i + 1))
        if ((i < last)); then args+=(down "$k" sleep 60); mods=("$k" "${mods[@]}"); else args+=(tap "$k" sleep 60); fi
      done
      for k in "${mods[@]}"; do args+=(up "$k"); done
      timeout 20 "$root/tests/tools/vkbd/vkbd.sh" "${args[@]}" >>"$log" 2>&1
    }
    nestctl dispatch "hl.dsp.focus({ window = 'address:$fixed_addr' })" >>"$log" 2>&1
    sleep 0.5
    chord Super_L Alt_L f
    sleep 1
    check "fixed keys: Super+Alt+F leaves the window of fixed size (was $fb0)" test "$(mode_box "$fixed_addr")" = "$fb0"
    check "fixed keys: the plugin refused the zoom" plugin_logged "window_size: maximized refused: window ${fixed_addr#0x} is of fixed size"
    chord Super_L Control_L f
    sleep 1
    check "fixed keys: Super+Ctrl+F leaves it too (was $fb0)" test "$(mode_box "$fixed_addr")" = "$fb0"
    check "fixed keys: the plugin refused the full screen" plugin_logged "window_size: fullscreen refused: window ${fixed_addr#0x} is of fixed size"
    unzoom "$addr" >/dev/null
    nestctl dispatch "hl.dsp.focus({ window = 'address:$addr' })" >>"$log" 2>&1
    sleep 0.5
    chord Super_L Alt_L f
    sleep 1
    check "fixed keys: Super+Alt+F zooms the control (the bind reaches the plugin: Fill, ADR-0036 D78)" zoomed "$addr"
    chord Super_L Alt_L f
    sleep 1
    unzoomed_now() { [[ $(mode_box "$addr" | cut -d' ' -f5) == 0 && $(fill_place "$addr") != fill ]]; }
    check "fixed keys: Super+Alt+F again unzooms it" unzoomed_now
    close_shell_popup "fixed keys"
    kill "$fixed_pid" 2>/dev/null
    sleep 0.5
  else
    check "fixed bar: the xdgact window opened" false
  fi

  # covered: a layer surface of a tiny Quickshell config (the run directory, never the repository): Exclusive or not, at a
  # place on GF-REF (layout coordinates x y w h).
  layer_pid=""
  start_layer() { # exclusive(0|1) x y w h
    mkdir -p "$run/layer-fixture"
    cat >"$run/layer-fixture/shell.qml" <<QML
import QtQuick
import Quickshell
import Quickshell.Wayland
ShellRoot {
    PanelWindow {
        screen: Quickshell.screens.find(s => s.name === "$out") ?? null
        anchors { top: true; left: true }
        margins { left: $(($2 - mx)); top: $(($3 - my)) }
        implicitWidth: $4
        implicitHeight: $5
        exclusionMode: ExclusionMode.Ignore
        color: "#40ff0000"
        WlrLayershell.layer: WlrLayer.Overlay
        WlrLayershell.namespace: "tiling-test-layer"
        WlrLayershell.keyboardFocus: $([[ $1 == 1 ]] && echo WlrKeyboardFocus.Exclusive || echo WlrKeyboardFocus.None)
    }
}
QML
    WAYLAND_DISPLAY=$sock HYPRLAND_INSTANCE_SIGNATURE=$DEV_NESTED_SIG DBUS_SESSION_BUS_ADDRESS="${bus:-disabled:}" \
      setsid "$root/scripts/dev/isolated.sh" --name tiling-layer qs -p "$run/layer-fixture" --no-color >>"$run/layer.log" 2>&1 </dev/null &
    layer_pid=$!
    pids+=("$layer_pid")
    local _
    for _ in $(seq 1 50); do
      nestctl layers -j 2>/dev/null | jq -e '[.. | objects | select(.namespace? == "tiling-test-layer")] | length > 0' >/dev/null 2>&1 && break
      sleep 0.1
    done
    sleep 0.3
  }
  # The layer gone as Hyprland reports it (integrator follow-up of PR #43: "the Exclusive layer gone, the hover works again"
  # flaked after a fixed 0.5 s while the layer was still mapped), then a moment for the plugin's layer listener.
  stop_layer() {
    [[ -n $layer_pid ]] && kill "$layer_pid" 2>/dev/null
    layer_pid=""
    local _
    for _ in $(seq 1 50); do
      nestctl layers -j 2>/dev/null | jq -e '[.. | objects | select(.namespace? == "tiling-test-layer")] | length == 0' >/dev/null 2>&1 && break
      sleep 0.1
    done
    sleep 0.3
  }
  no_enter_for() { # seconds: the pointer rests on the light, no enter comes
    mark_events
    pointer abs $((lcx - mx)) $((lcy - my)) sleep 100
    sleep "$1"
    [[ -z $(events_since "$(hover_filter enter)") ]]
  }
  enter_again() { # off the light and back: the hover works again, its enter within the delay + 2 s
    pointer abs $((lcx - mx + 300)) $((lcy - my + 200)) sleep 200
    mark_events
    pointer abs $((lcx - mx)) $((lcy - my)) sleep 100
    local _ ok=1
    for _ in $(seq 1 $(((hover_delay + 2000) / 100))); do
      events_since "$(hover_filter enter)" | grep -q . && { ok=0; break; }
      sleep 0.1
    done
    ((ok)) && surfaces_state
    close_popover
    return $ok
  }
  enter_unmoved() { # the pointer rests on the light: an enter comes by itself (since mark_events) within the delay + 2 s
    local _ ok=1
    for _ in $(seq 1 $(((hover_delay + 2000) / 100))); do
      events_since "$(hover_filter enter)" | grep -q . && { ok=0; break; }
      sleep 0.1
    done
    ((ok)) && surfaces_state
    close_popover
    return $ok
  }
  wait_s=$(awk -v d="$hover_delay" 'BEGIN { print (d + 700) / 1000 }')
  if [[ -n $open_event ]]; then
    pointer abs $((lcx - mx + 300)) $((lcy - my + 200)) sleep 200
    start_layer 1 $((mx + mw - 160)) $((my + mh - 120)) 120 80
    check "covered: no enter while an Exclusive layer is mapped elsewhere on the output" no_enter_for "$wait_s"
    stop_layer
    check "covered: the Exclusive layer gone, the hover works again" enter_again
    pointer abs $((lcx - mx + 300)) $((lcy - my + 200)) sleep 200
    start_layer 0 $((lcx - 20)) $((lcy - 20)) 40 40
    check "covered: no enter while a layer covers the light" no_enter_for "$wait_s"
    stop_layer
    check "covered: the layer gone, the hover works again" enter_again
    pointer abs $((lcx - mx + 300)) $((lcy - my + 200)) sleep 200
    mark_events
    pointer abs $((lcx - mx)) $((lcy - my)) sleep 100
    sleep "$(awk -v d="$hover_delay" 'BEGIN { print (d + 500) / 1000 }')"
    check "covered: a hover before the lock" event_came "$(hover_filter enter)"
    close_popover
    if lock_session; then
      pointer abs $((lcx - mx + 300)) $((lcy - my + 200)) sleep 200
      check "covered: no enter while the session is locked" no_enter_for "$wait_s"
    else
      check "covered: the foreign locker holds the session lock (${locked:-no answer})" false
    fi
    mark_events # the pointer rests on the light from here on
    check "covered: released, Hyprland reports the session unlocked" unlock_session
    check "covered: unlocked, the hover works again with the pointer resting on the light" enter_unmoved
  fi

  other=$(nestctl monitors -j | jq -r --arg o "$out" '[.[] | select(.name != $o)][0].name // ""')
  if [[ -n $other ]]; then
    free_foot
    area_now
    nestctl dispatch "hl.plugin.grassfield.tile(\"$addr\", \"left\")" >>"$log" 2>&1
    sleep 0.8
    move_to "$other"
    read -r oax oay oaw oah < <(area_of "$other")
    check "move-to: the tiled window takes the left half of $other" is_box $((oax + m)) $((oay + m + tb)) $(((oaw - 3 * m) / 2)) $((oah - 2 * m - tb))
    check "move-to: still tiled" record_is "$addr" tiled
    on_desktop_of() { # output
      local ws want
      ws=$(nestctl clients -j | jq -r --arg a "$addr" '.[] | select(.address == $a) | .workspace.id')
      want=$(nestctl monitors -j | jq -r --arg o "$1" '.[] | select(.name == $o) | .activeWorkspace.id')
      say "  Desktop $ws (want $want, $1's)"
      [[ -n $ws && $ws == "$want" ]]
    }
    check "move-to: it is on $other's Desktop" on_desktop_of "$other"
    area_now
    move_to "$out"
    check "move-to: back on $out, its left half" is_box $((ax + m)) "$ry" "$halfw" "$fullh"
    free_foot
    read -r _ _ fw fh _ < <(geometry)
    move_to "$other"
    free_on_other() {
      local x y w h _a
      read -r x y w h _a < <(geometry)
      say "  ${w}x${h} at $x,$y (want ${fw}x${fh}, at most ${oaw}x${oah}, its middle on $other at $oax,$oay)"
      (( x + w / 2 >= oax && x + w / 2 < oax + oaw && y + h / 2 >= oay && y + h / 2 < oay + oah )) &&
        (( (w == fw || w <= oaw) && (h == fh || h <= oah) ))
    }
    check "move-to: a Free window keeps its size and lands on $other" free_on_other
    check "move-to: still Free" record_is "$addr" none
    move_to "$out"
  else
    say "SKIP: move-to (one output: the Move to <display> rows are not shown either)"
  fi

  free_foot
  read -r bx by bw bh _ < <(geometry)
  mark_events
  move_to "NO-SUCH-OUTPUT"
  check "move-invalid: an unknown output is refused (reason invalid)" event_came '.type == "tiling" and .reason == "invalid"'
  mark_events
  move_to "$out"
  check "move-invalid: the window's own output is refused (reason invalid)" event_came '.type == "tiling" and .reason == "invalid"'
  check "move-invalid: nothing moved" is_box "$bx" "$by" "$bw" "$bh"
  close_popover # nothing of the shell's popover left over the windows of the C1 cases
else
  say "SKIP: step 3 cases (the plugin does not advertise tile-hover)"
fi

if nestctl -j grassfield 2>/dev/null | jq -e '.features | (index("tiling-layouts") != null and index("tile-hover") != null)' >/dev/null 2>&1 && [[ -n ${addr2:-} ]]; then
  env -u DISPLAY WAYLAND_DISPLAY="$sock" DBUS_SESSION_BUS_ADDRESS="$bus" setsid "$root/scripts/dev/isolated.sh" --name tiling \
    foot -T tiling-foot3 -w 600x400 sh -c 'exec sleep 100000' >>"$run/foot.out" 2>&1 </dev/null &
  foot3_pid=$!
  pids+=("$foot3_pid")
  for _ in $(seq 1 100); do [[ -n $(geometry_of tiling-foot3) ]] && break; sleep 0.2; done
  sleep 1
  read -r _ _ _ _ addr3 < <(geometry_of tiling-foot3)
  free_foot
  nestctl dispatch "hl.plugin.grassfield.tile(\"$addr2\", \"previous\")" >>"$log" 2>&1
  nestctl dispatch "hl.dsp.window.move({ x = $((mx + 500)), y = $((my + 300)), window = 'address:$addr2' })" >>"$log" 2>&1
  [[ -n ${addr3:-} ]] && nestctl dispatch "hl.dsp.window.move({ x = $((mx + 700)), y = $((my + 350)), window = 'address:$addr3' })" >>"$log" 2>&1
  nestctl dispatch "hl.dsp.focus({ window = 'address:$addr' })" >>"$log" 2>&1
  sleep 0.8
  suggestion() { tiling_state | jq -c '.suggestion'; }
  record_of() { tiling_state | jq -c --arg a "${1#0x}" '[.outputs[].windows[] | select(.address == $a)][0] // null'; }
  check "step 4a: the third foot window opened" test -n "${addr3:-}"

  area_now
  mark_events
  arrange "{\"layout\":\"thirds\",\"windows\":[\"$addr\"],\"zone\":2}"
  check "zone: the plugin posts placed" event_came '.type == "tiling" and .reason == "placed"'
  zone_gen=$(jq -r '.gen' <<<"${last_event:-null}")
  zone_alone() {
    local r
    r=$(record_of "$addr")
    say "  record: $r"
    jq -e '.state == "tiled" and .layout == "thirds" and .zone == 2 and .group == 0' <<<"$r" >/dev/null
  }
  check "zone: the first window alone in the right third, no group" zone_alone
  first_suggestion() {
    local sg
    sg=$(suggestion)
    say "  suggestion: $sg"
    jq -e --arg a "${addr#0x}" --arg b "${addr2#0x}" --arg o "$out" --argjson gen "${zone_gen:-null}" --argjson ax "$ax" --argjson aw "$aw" \
      '.gen == $gen and .address == $a and .layout == "thirds" and .output == $o and ([.zones[].zone] == [0, 1])
       and all(.zones[]; .w > 0 and .h > 0 and .x >= $ax and .x + .w <= $ax + $aw) and (.windows | index($b) != null) and (.windows | index($a) == null)' <<<"$sg" >/dev/null
  }
  check "zone: the suggestion of that notice offers zones 0 and 1 with the other windows, not the first" first_suggestion

  arrange "{\"layout\":\"thirds\",\"windows\":[\"$addr2\"],\"zone\":0,\"with\":\"$addr\"}"
  picked() { # address zone
    local a b
    a=$(record_of "$addr")
    b=$(record_of "$1")
    say "  first: $a; picked: $b"
    jq -e -n --argjson a "$a" --argjson b "$b" --argjson z "$2" '$b.state == "tiled" and $b.layout == "thirds" and $b.zone == $z and $b.group > 0 and $b.group == $a.group and $a.zone == 2' >/dev/null
  }
  check "pick: the second window takes the left third, in the first's group" picked "$addr2" 0
  zone_one() {
    local sg
    sg=$(suggestion)
    say "  suggestion: $sg"
    jq -e --arg c "${addr3#0x}" '[.zones[].zone] == [1] and (.windows | index($c) != null)' <<<"$sg" >/dev/null
  }
  check "pick: the suggestion now offers zone 1" zone_one

  read -r b3x b3y b3w b3h _ < <(geometry_of tiling-foot3)
  mark_events
  arrange "{\"layout\":\"thirds\",\"windows\":[\"$addr3\"],\"zone\":2,\"with\":\"$addr\"}"
  check "pick-held: a pick into a held zone is refused (reason invalid)" event_came '.type == "tiling" and .reason == "invalid"'
  check "pick-held: nothing moved" box_of tiling-foot3 "$b3x" "$b3y" "$b3w" "$b3h"
  check "pick-held: the suggestion stays" zone_one

  tile_ipc "$addr2" previous
  check "stale: another change ends the suggestion" test "$(suggestion)" = null

  # suggest-off: "Suggest windows to fill the rest of a layout" off (TL32).
  suggests_again() {
    local sg
    sg=$(suggestion)
    say "  suggestion: $sg"
    jq -e --arg a "${addr#0x}" '.address == $a and ([.zones[].zone] == [0, 1])' <<<"$sg" >/dev/null
  }
  arrange "{\"layout\":\"thirds\",\"windows\":[\"$addr\"],\"zone\":2}"
  check "suggest-off: switched on, a zone placement has its suggestion" suggests_again
  nestctl dispatch "hl.plugin.grassfield.config(\"tilingSuggestions\", \"false\")" >>"$log" 2>&1
  check "suggest-off: the pending suggestion ends with the switch" test "$(suggestion)" = null
  nestctl dispatch "hl.plugin.grassfield.config(\"tilingSuggestions\", \"true\")" >>"$log" 2>&1
  check "suggest-off: it does not come back when the switch turns on" test "$(suggestion)" = null
  nestctl dispatch "hl.plugin.grassfield.config(\"tilingSuggestions\", \"false\")" >>"$log" 2>&1
  mark_events
  arrange "{\"layout\":\"thirds\",\"windows\":[\"$addr\"],\"zone\":2}"
  check "suggest-off: the zone placement posts placed" event_came '.type == "tiling" and .reason == "placed"'
  check "suggest-off: the reply has no suggestion" test "$(suggestion)" = null
  nestctl dispatch "hl.plugin.grassfield.config(\"tilingSuggestions\", \"true\")" >>"$log" 2>&1
  arrange "{\"layout\":\"thirds\",\"windows\":[\"$addr\"],\"zone\":2}"
  check "suggest-off: on again, the same placement has a suggestion" suggests_again

  nestctl dispatch "hl.plugin.grassfield.minimize(\"$addr3\")" >>"$log" 2>&1
  sleep 1
  workspace_of() { nestctl clients -j | jq -r --arg a "$1" '.[] | select(.address == $a) | .workspace.name'; }
  check "minimized: the third window waits on special:minimized" test "$(workspace_of "$addr3")" = special:minimized
  arrange "{\"layout\":\"thirds\",\"windows\":[\"$addr\"],\"zone\":2}"
  offers_minimized() {
    local sg
    sg=$(suggestion)
    say "  suggestion: $sg"
    jq -e --arg c "${addr3#0x}" '.windows | index($c) != null' <<<"$sg" >/dev/null
  }
  check "minimized: the suggestion offers it" offers_minimized
  arrange "{\"layout\":\"thirds\",\"windows\":[\"$addr3\"],\"zone\":1,\"with\":\"$addr\"}"
  on_desktop() {
    local ws want
    ws=$(workspace_of "$addr3")
    want=$(nestctl monitors -j | jq -r --arg o "$out" '.[] | select(.name == $o) | .activeWorkspace.name')
    say "  Desktop $ws (want $want)"
    [[ -n $ws && $ws == "$want" ]]
  }
  check "minimized: the pick brings it back to $out's Desktop" on_desktop
  check "minimized: in the middle third, in the first's group" picked "$addr3" 1

  # Step 4b (TL29): the first and the third windows are one group now; the second has none.
  if nestctl -j grassfield 2>/dev/null | jq -e '.features | index("tiling-groups")' >/dev/null 2>&1; then
    group_front() { nestctl dispatch "hl.plugin.grassfield.group_front(\"$1\")" >>"$log" 2>&1; sleep 0.8; }
    order_now() { nestctl clients -j | jq -c 'map(.address)'; }
    # Each window above the one before it in Hyprland's stacking order (`clients` lists it bottom first).
    above() { # address...
      local order a i prev=-1 seen=""
      order=$(order_now)
      for a in "$@"; do
        i=$(jq -r --arg a "$a" 'index($a) // -1' <<<"$order")
        seen+=" $a:$i"
        (( i > prev )) || { say "  stack:$seen"; return 1; }
        prev=$i
      done
      say "  stack:$seen"
    }
    nestctl dispatch "hl.dsp.focus({ window = 'address:$addr2' })" >>"$log" 2>&1
    sleep 0.5
    group_below() { above "$addr3" "$addr2" && above "$addr" "$addr2"; }
    check "group-front: the second window (no group) is above the group first" group_below
    group_front "$addr"
    check "group-front: the group comes forward, the chosen window in front" above "$addr2" "$addr3" "$addr"
    check "group-front: the focus stays where it was (no activation)" test "$(nestctl activewindow -j | jq -r '.address')" = "$addr2"
    before=$(order_now)
    group_front "$addr2"
    check "group-front: a window in no group changes nothing" test "$(order_now)" = "$before"
    mark_events
    group_front "0x1"
    check "group-front: an unknown window is refused (reason invalid)" event_came '.type == "tiling" and .reason == "invalid"'
    # Zoomed, then full screen, and focused (integrator review of cd74af2): Suspended but on screen, the chosen window still
    # ends above its group (the protocol activation does nothing for the focused window).
    for mode in maximized fullscreen; do
      nestctl dispatch "hl.dsp.window.fullscreen({ mode = \"$mode\", window = \"address:$addr\" })" >>"$log" 2>&1
      nestctl dispatch "hl.dsp.focus({ window = 'address:$addr' })" >>"$log" 2>&1
      sleep 0.8
      check "group-front $mode: the first window's tile is suspended" test "$(record_of "$addr" | jq -r '.state')" = suspended
      group_front "$addr"
      check "group-front $mode: the chosen window stays above its group" above "$addr3" "$addr"
      nestctl dispatch "hl.dsp.window.fullscreen({ mode = \"$mode\", window = \"address:$addr\" })" >>"$log" 2>&1
      sleep 0.8
    done
    check "group-front: the first window is tiled again after zoom and full screen" test "$(record_of "$addr" | jq -r '.state')" = tiled
    nestctl dispatch "hl.dsp.focus({ window = 'address:$addr2' })" >>"$log" 2>&1
    sleep 0.5
    if lock_session; then
      before=$(order_now)
      mark_events
      group_front "$addr3"
      check "group-front locked: refused (reason locked)" event_came '.type == "tiling" and .reason == "locked"'
      check "group-front locked: nothing is raised" test "$(order_now)" = "$before"
    else
      check "group-front locked: the foreign locker holds the session lock (${locked:-no answer})" false
    fi
    check "group-front locked: released, Hyprland reports the session unlocked" unlock_session
    sleep 0.5
  else
    say "SKIP: step 4b cases (the plugin does not advertise tiling-groups)"
  fi

  # Step 4c (TL30): the third and the first windows, the middle and right thirds, are one group side by side.
  if nestctl -j grassfield 2>/dev/null | jq -e '.features | index("tiling-shared-edge")' >/dev/null 2>&1; then
    read -r lx ly lw lh _ < <(geometry_of tiling-foot3)
    read -r rx0 ry0 rw0 rh0 _ < <(geometry_of tiling-foot)
    gap=$((rx0 - lx - lw))
    # The handle: the middle of the stretch the two frames share (titlebars included), in the gap; GF-REF coordinates.
    hx=$((lx + lw + gap / 2 - mx)) hy=$((ly - tb + (lh + tb) / 2 - my))
    say "  shared edge: ${gap} px between the third window (right side $((lx + lw))) and the first ($rx0), handle at $hx,$hy"
    edge_group() {
      local a b
      a=$(record_of "$addr")
      b=$(record_of "$addr3")
      say "  first: $a; third: $b"
      jq -e -n --argjson a "$a" --argjson b "$b" '$a.state == "tiled" and $b.state == "tiled" and $a.group > 0 and $a.group == $b.group' >/dev/null
    }
    mark_events
    pointer abs "$hx" "$hy" sleep 300 down drag $((hx + 60)) "$hy" sleep 200 up sleep 400
    check "shared-edge: the plugin posts resized" event_came '.type == "tiling" and .reason == "resized"'
    check "shared-edge: the left window grew with the drag" box_of tiling-foot3 "$lx" "$ly" $((lw + 60)) "$lh"
    check "shared-edge: the right window followed, the gap kept" box_of tiling-foot $((rx0 + 60)) "$ry0" $((rw0 - 60)) "$rh0"
    check "shared-edge: both still tiled, in one group" edge_group
    # D60 (step 6b): only a Split View's separator resets at a double-click; an ordinary group's edge keeps where it was put.
    pointer abs $((hx + 60)) "$hy" sleep 300 down sleep 40 up sleep 100 down sleep 40 up sleep 500
    check "shared-edge: a double-click does not reset an ordinary group's edge" box_of tiling-foot3 "$lx" "$ly" $((lw + 60)) "$lh"
    pointer abs $((hx + 60)) "$hy" sleep 300 down drag "$hx" "$hy" sleep 200 up sleep 400
    check "shared-edge: dragged back" box_of tiling-foot3 "$lx" "$ly" "$lw" "$lh"
    check "shared-edge: the right window back too" box_of tiling-foot "$rx0" "$ry0" "$rw0" "$rh0"
    # A window in front of the handle gets the click (TL30, TL34; integrator review of a6d04df: the frontmost window under
    # the pointer always does): a foot that reports the mouse (xterm mode 1000; what it reads goes to a file) is centred on
    # the handle, then zoomed, then full screen. Each time the drag over the handle reaches foot and moves neither window.
    mouse_log=$run/mouse-reports
    : >"$mouse_log"
    env -u DISPLAY WAYLAND_DISPLAY="$sock" DBUS_SESSION_BUS_ADDRESS="$bus" setsid "$root/scripts/dev/isolated.sh" --name tiling \
      foot -T tiling-mouse -w 500x300 sh -c 'stty raw -echo; printf "\033[?1000h"; exec cat >"$0"' "$mouse_log" >>"$run/foot.out" 2>&1 </dev/null &
    mouse_pid=$!
    pids+=("$mouse_pid")
    for _ in $(seq 1 100); do [[ -n $(geometry_of tiling-mouse) ]] && break; sleep 0.2; done
    sleep 1
    read -r _ _ _ _ maddr < <(geometry_of tiling-mouse)
    if [[ -n ${maddr:-} ]]; then
      nestctl dispatch "hl.dsp.window.move({ x = $((mx + hx - 250)), y = $((my + hy - 150)), window = 'address:$maddr' })" >>"$log" 2>&1
      nestctl dispatch "hl.dsp.focus({ window = 'address:$maddr' })" >>"$log" 2>&1
      sleep 0.8
      for mode in plain maximized fullscreen; do
        if [[ $mode != plain ]]; then
          nestctl dispatch "hl.dsp.window.fullscreen({ mode = \"$mode\", window = \"address:$maddr\" })" >>"$log" 2>&1
          sleep 0.8
        fi
        before=$(stat -c %s "$mouse_log" 2>/dev/null || echo 0)
        pointer abs 20 $((mh / 2)) sleep 200 abs "$hx" "$hy" sleep 300 down drag $((hx + 60)) "$hy" sleep 200 up sleep 400
        after=$(stat -c %s "$mouse_log" 2>/dev/null || echo 0)
        say "  covered ($mode): foot read $((after - before)) byte(s) of mouse reports"
        check "shared-edge covered ($mode): the foot in front gets the click" test "$after" -gt "$before"
        check "shared-edge covered ($mode): the left window did not move" box_of tiling-foot3 "$lx" "$ly" "$lw" "$lh"
        check "shared-edge covered ($mode): nor the right one" box_of tiling-foot "$rx0" "$ry0" "$rw0" "$rh0"
        if [[ $mode != plain ]]; then
          nestctl dispatch "hl.dsp.window.fullscreen({ mode = \"$mode\", window = \"address:$maddr\" })" >>"$log" 2>&1
          sleep 0.8
        fi
      done
    else
      check "shared-edge covered: the mouse-reporting foot opened" false
    fi
    kill "$mouse_pid" 2>/dev/null
    for _ in $(seq 1 25); do [[ -z $(geometry_of tiling-mouse) ]] && break; sleep 0.2; done
    # A drag far past the right window's minimum (TL8: the app's, never under Hyprland's 20 px floor; integrator review of
    # a6d04df): the edge stops there, the gap kept and the right window's right side where it was; then dragged back.
    pointer abs "$hx" "$hy" sleep 300 down drag $((mw - 2)) "$hy" sleep 200 up sleep 600
    at_minimum() {
      local x w _y _h _a l
      read -r x _y w _h _a < <(geometry_of tiling-foot)
      read -r _ _ l _ _ < <(geometry_of tiling-foot3)
      say "  right window ${w} px wide at $x (right side $((x + w)), was $((rx0 + rw0))), the left one $l px wide, gap $((x - lx - l))"
      ((w >= 20 && w < rw0 / 2 && x + w - rx0 - rw0 <= 1 && rx0 + rw0 - x - w <= 1 && x - lx - l - gap <= 1 && gap - x + lx + l <= 1))
    }
    check "shared-edge minimum: the edge stops at the right window's minimum, the gap kept" at_minimum
    read -r _ _ lw_now _ _ < <(geometry_of tiling-foot3)
    hx_now=$((lx + ${lw_now:-$lw} + gap / 2 - mx))
    pointer abs "$hx_now" "$hy" sleep 300 down drag "$hx" "$hy" sleep 200 up sleep 600
    check "shared-edge minimum: dragged back" box_of tiling-foot3 "$lx" "$ly" "$lw" "$lh"
    check "shared-edge minimum: the right window back too" box_of tiling-foot "$rx0" "$ry0" "$rw0" "$rh0"
    # While the foreign locker holds the session lock the handle takes nothing (TL34): no window moves.
    if lock_session; then
      pointer abs "$hx" "$hy" sleep 300 down drag $((hx + 60)) "$hy" sleep 200 up sleep 400
      check "shared-edge locked: the left window did not move" box_of tiling-foot3 "$lx" "$ly" "$lw" "$lh"
      check "shared-edge locked: nor the right one" box_of tiling-foot "$rx0" "$ry0" "$rw0" "$rh0"
    else
      check "shared-edge locked: the foreign locker holds the session lock (${locked:-no answer})" false
    fi
    check "shared-edge locked: released, Hyprland reports the session unlocked" unlock_session
    sleep 0.5
    # The first press after the unlock is the user's (macOS: the first click after unlocking acts; integrator nested pass of
    # 5d3dc49): the handle, pressed 0.5 s after the unlock with no other motion first, moves the edge, then back.
    pointer abs "$hx" "$hy" sleep 300 down drag $((hx + 60)) "$hy" sleep 200 up sleep 400
    check "shared-edge after the unlock: the first press on the handle moves the edge" box_of tiling-foot3 "$lx" "$ly" $((lw + 60)) "$lh"
    check "shared-edge after the unlock: the right window followed" box_of tiling-foot $((rx0 + 60)) "$ry0" $((rw0 - 60)) "$rh0"
    pointer abs $((hx + 60)) "$hy" sleep 300 down drag "$hx" "$hy" sleep 200 up sleep 400
    check "shared-edge after the unlock: dragged back" box_of tiling-foot3 "$lx" "$ly" "$lw" "$lh"
    # The lock during a drag ends it at once (TL34; integrator review of a6d04df): the button held, 30 px, then the lock,
    # then 60 px more and the release. The lock itself ends the drag: both records are Tiled while still locked, before any
    # motion follows (integrator re-review of ce82fd3: the next motion would end it too); the windows keep the frames of the
    # motions before the lock. The hold (12 s) outlasts the locker's start (lock_session waits up to 6 s).
    pointer abs "$hx" "$hy" sleep 300 down drag $((hx + 30)) "$hy" sleep 12000 drag $((hx + 90)) "$hy" sleep 200 up &
    held_pid=$!
    sleep 1.5
    if lock_session; then
      locked_tiled() {
        local a b
        a=$(record_of "$addr" | jq -r '.state // "none"')
        b=$(record_of "$addr3" | jq -r '.state // "none"')
        say "  while locked, before the next motion: first $a, third $b"
        [[ $a == tiled && $b == tiled ]]
      }
      check "shared-edge lock mid-drag: the lock itself ended the drag (both Tiled while locked, before the next motion)" locked_tiled
      wait "$held_pid"
      check "shared-edge lock mid-drag: the left window kept the frame of before the lock" box_of tiling-foot3 "$lx" "$ly" $((lw + 30)) "$lh"
      check "shared-edge lock mid-drag: the right one too" box_of tiling-foot $((rx0 + 30)) "$ry0" $((rw0 - 30)) "$rh0"
    else
      wait "$held_pid"
      check "shared-edge lock mid-drag: the foreign locker holds the session lock (${locked:-no answer})" false
    fi
    check "shared-edge lock mid-drag: released, Hyprland reports the session unlocked" unlock_session
    sleep 0.5
    check "shared-edge lock mid-drag: both tiled again, in one group" edge_group
    pointer abs $((hx + 30)) "$hy" sleep 300 down drag "$hx" "$hy" sleep 200 up sleep 400
    check "shared-edge lock mid-drag: dragged back" box_of tiling-foot3 "$lx" "$ly" "$lw" "$lh"
    check "shared-edge lock mid-drag: the right window back too" box_of tiling-foot "$rx0" "$ry0" "$rw0" "$rh0"
    # Outside the handle the edge resizes one window as usual (Hyprland's resize_on_border). The point is in the margin 20 px
    # below the windows' surface tops, well outside the handle (the middle 120 px of their common stretch) and below the
    # titlebar row (the integrator's probe: Hyprland resizes one window there); the pointer settles on the wallpaper first.
    oy=$((ly + 20 - my))
    pointer abs 20 $((mh / 2)) sleep 300 abs "$hx" "$oy" sleep 400
    say "  outside the handle at $hx,$oy: hyprctl locked $(hypr_locked), cursor $(nestctl cursorpos 2>/dev/null), active $(nestctl activewindow -j 2>/dev/null | jq -r '.title // "none"')"
    surfaces_state
    pointer down drag $((hx + 40)) "$oy" sleep 200 up sleep 600
    only_one() {
      local l r moved=0
      read -r l < <(geometry_of tiling-foot3 | cut -d' ' -f1-4)
      read -r r < <(geometry_of tiling-foot | cut -d' ' -f1-4)
      [[ $l != "$lx $ly $lw $lh" ]] && moved=$((moved + 1))
      [[ $r != "$rx0 $ry0 $rw0 $rh0" ]] && moved=$((moved + 1))
      say "  third window $l, first window $r: $moved changed"
      ((moved == 1))
    }
    check "shared-edge: outside the handle one window is resized, the other stays" only_one
  else
    say "SKIP: step 4c cases (the plugin does not advertise tiling-shared-edge)"
  fi

  # ADR-0036 D69 (capture defect of 2026-10-30: Quarters at 1440 x 900 with a window taller than a quarter came out with
  # shifted rows): a window is placed only in a zone it fits. An xdgact window at least half the output plus 200 px wide fits
  # the top and bottom halves (the whole width) and no quarter nor left or right half: the popover's event lists those zones;
  # a quarter is refused and moves nothing, the top half places it; Quarters asked by it is refused; Quarters asked by an
  # ordinary window leaves it out (each zone takes the topmost window that fits it) and comes out aligned; the reply lists it.
  tile_ipc "$addr" previous
  tile_ipc "$addr2" previous
  tile_ipc "$addr3" previous
  open_xdg gf-fit-wide $((mw / 2 + 200))
  if [[ -n $xdg_addr ]]; then
    fit_open() { # address jq-condition: tile_popover posts open for that window, the condition holding on its event
      mark_events
      nestctl dispatch "hl.plugin.grassfield.tile_popover(\"$1\")" >>"$log" 2>&1
      event_came ".type == \"tile-hover\" and .address == \"${1#0x}\" and .state == \"open\" and $2"
      local ok=$?
      say "  event: $last_event"
      close_shell_popup "fit wide"
      return $ok
    }
    check "fit wide: its event lists the quarters and the left and right halves, not the top half" fit_open "$xdg_addr" \
      '(.unfitZones | (index("0,0,6,6") != null and index("6,6,6,6") != null and index("0,0,6,12") != null and index("6,0,6,12") != null and index("0,0,12,6") == null))'
    check "fit wide: an ordinary window's event lists no zone" fit_open "$addr" '.unfitZones == []'
    xdg_box() { nestctl clients -j | jq -r --arg a "$xdg_addr" '.[] | select(.address == $a) | "\(.at[0]) \(.at[1]) \(.size[0]) \(.size[1])"'; }
    wb=$(xdg_box)
    mark_events
    tile_ipc "$xdg_addr" top-left
    check "fit wide: tile to a quarter is refused (reason invalid)" event_came '.type == "tiling" and .reason == "invalid"'
    check "fit wide: the refusal moved nothing (was $wb)" test "$(xdg_box)" = "$wb"
    check "fit wide: the refusal left no record" test "$(record_of "$xdg_addr")" = null
    mark_events
    tile_ipc "$xdg_addr" top
    check "fit wide: the top half places it" event_came '.type == "tiling" and .reason == "placed"'
    check "fit wide: its record is the top half" test "$(record_of "$xdg_addr" | jq -r '.place')" = top
    tile_ipc "$xdg_addr" previous
    wb=$(xdg_box)
    mark_events
    arrange "{\"layout\":\"quarters\",\"windows\":[\"$xdg_addr\"]}"
    check "fit wide: Quarters asked by it is refused (reason invalid)" event_came '.type == "tiling" and .reason == "invalid"'
    check "fit wide: that refusal moved nothing (was $wb)" test "$(xdg_box)" = "$wb"
    nestctl dispatch "hl.dsp.focus({ window = 'address:$xdg_addr' })" >>"$log" 2>&1 # the topmost window: the fill meets it first
    sleep 0.5
    wb=$(xdg_box)
    mark_events
    arrange "{\"layout\":\"quarters\",\"windows\":[\"$addr\"]}"
    check "fit wide: Quarters asked by an ordinary window is placed" event_came '.type == "tiling" and .reason == "placed"'
    check "fit wide: its fill leaves the wide window out (no record, not moved; was $wb)" test "$(record_of "$xdg_addr"):$(xdg_box)" = "null:$wb"
    quarters_aligned() {
      local q
      q=$(tiling_state | jq -c '[.outputs[].windows[] | select(.layout == "quarters" and .state == "tiled") | {zone, x, y, w, h}]')
      say "  quarters: $q"
      jq -e 'length >= 2
        and ([.[] | select(.zone == 0 or .zone == 1) | [.y, .h]] | unique | length <= 1)
        and ([.[] | select(.zone == 2 or .zone == 3) | [.y, .h]] | unique | length <= 1)
        and ([.[] | select(.zone == 0 or .zone == 2) | [.x, .w]] | unique | length <= 1)
        and ([.[] | select(.zone == 1 or .zone == 3) | [.x, .w]] | unique | length <= 1)' <<<"$q" >/dev/null
    }
    check "fit wide: the quarters placed share their rows and columns" quarters_aligned
    "$root/scripts/dev/shot.sh" tiling-fit-wide-quarters "$out" >>"$log" 2>&1 && cp "$dev/shots/tiling-fit-wide-quarters.png" "$run/" 2>/dev/null
    reply_lists_wide() {
      local z
      z=$(tiling_state | jq -c --arg a "${xdg_addr#0x}" '[.unfitZones[] | select(.address == $a) | .zones][0] // null')
      say "  reply unfitZones of the wide window: $z"
      jq -e 'index("0,0,6,6") != null and index("0,0,12,6") == null' <<<"$z" >/dev/null
    }
    check "fit wide: the reply lists its unfit zones" reply_lists_wide
    for a in $(tiling_state | jq -r '.outputs[].windows[] | select(.layout == "quarters") | "0x" + .address'); do
      tile_ipc "$a" previous
    done
    kill "$xdg_pid" 2>/dev/null
    sleep 0.5
  else
    check "fit wide: the xdgact window opened" false
  fi

  # Step 6a (TL33, ADR-0036 D41-D47): Full Screen › Left or Right of Screen makes a Split View Desktop. Every window back to
  # its box from before first; the first window goes left, the second is picked into the right half.
  if nestctl -j grassfield 2>/dev/null | jq -e '.features | index("tiling-split")' >/dev/null 2>&1; then
    tile_ipc "$addr" previous
    tile_ipc "$addr3" previous
    split_ipc() { nestctl dispatch "hl.plugin.grassfield.split(\"$1\", \"$2\")" >>"$log" 2>&1; sleep 1; }
    unsplit_ipc() { nestctl dispatch "hl.plugin.grassfield.unsplit(\"$1\")" >>"$log" 2>&1; sleep 1; }
    shown_desktop() { nestctl monitors -j | jq -r --arg o "$out" '.[] | select(.name == $o) | .activeWorkspace.id'; }
    desktop_of() { nestctl clients -j | jq -r --arg a "$1" '.[] | select(.address == $a) | .workspace.id'; }
    move_off() { nestctl dispatch "hl.dsp.window.move({ workspace = \"$2\", follow = false, window = \"address:$1\" })" >>"$log" 2>&1; sleep 1; }
    near() { (( $1 - $2 <= $3 && $2 - $1 <= $3 )); }
    split_listed() { # workspace home: the reply lists that Split View Desktop
      local sp
      sp=$(tiling_state | jq -c '.splits')
      say "  splits: $sp"
      jq -e --argjson w "$1" --argjson h "$2" --arg o "$out" 'any(.[]; .workspace == $w and .home == $h and .output == $o)' <<<"$sp" >/dev/null
    }
    split_gone() { ! split_listed "$1" "$2"; }
    split_members() { # workspace address...: the reply lists exactly these members, in this order
      local got want
      got=$(tiling_state | jq -c --argjson w "$1" '[.splits[] | select(.workspace == $w) | .windows][0] // null')
      shift
      want=$(printf '%s\n' "$@" | sed 's/^0x//' | jq -R . | jq -sc .)
      say "  members: $got (want $want)"
      [[ $got == "$want" ]]
    }
    # Step 6e (TL33, ADR-0036 D73): with tiling-split-titles a member's titlebar is away, no band above it (its half fills
    # from the output's top edge); its bar is revealed by the pointer at the top edge over its half, below the menu bar.
    split_titles=0 stb=$tb
    if nestctl -j grassfield 2>/dev/null | jq -e '.features | index("tiling-split-titles")' >/dev/null 2>&1; then
      split_titles=1 stb=0
    fi
    split_inset=$(nestctl layers -j 2>/dev/null | jq -r --arg o "$out" '[.[$o].levels[][]? | select(.namespace == "grassfield-menubar") | .h] | max // 0')
    [[ $split_inset =~ ^[0-9]+$ ]] || split_inset=0
    say "  split titles: $([[ $split_titles == 1 ]] && echo "away (revealed below a menu bar strip of $split_inset px)" || echo shown)"
    reveal_over() { # x (relative to $out): the pointer at the top edge over x, which reveals that half's bar (6e; nothing before)
      ((split_titles)) && pointer abs "$1" $((mh / 2)) sleep 100 abs "$1" 0 sleep 300
      return 0
    }
    member_grip() { # address: where a press drags a member, "px py": the middle of its revealed bar (6e), else of its titlebar
      if ((split_titles)); then
        nestctl clients -j | jq -r --arg a "$1" --argjson mx "$mx" --argjson y "$((split_inset + GF_TB_MID))" \
          '.[] | select(.address == $a) | "\((.at[0] + .size[0] / 2 - $mx) | floor) \($y)"' | grep .
      else
        grip_of "$1"
      fi
    }
    green_click() { # address: a click on its zoom light (found through tile_popover, the popover closed first; 6e: on its
      # revealed bar, the pointer at the top edge over its half first)
      local ev lx ly wx
      if ((split_titles)) && split_members_of "$1"; then
        wx=$(nestctl clients -j | jq -r --arg a "$1" --argjson mx "$mx" '.[] | select(.address == $a) | (.at[0] - $mx) | floor')
        reveal_over $((wx + GF_TB_ZOOM_X + 40))
        pointer abs $((wx + GF_TB_ZOOM_X)) $((split_inset + GF_TB_MID)) sleep 150 down sleep 80 up sleep 300
        pointer abs 20 $((mh / 2)) sleep 200
        sleep 0.8
        return 0
      fi
      mark_events
      nestctl dispatch "hl.plugin.grassfield.tile_popover(\"$1\")" >>"$log" 2>&1
      event_came ".type == \"tile-hover\" and .address == \"${1#0x}\" and .state == \"open\"" || return 1
      ev=$last_event
      close_popover
      read -r lx ly < <(jq -r '"\((.x + .w / 2) | floor) \((.y + .h / 2) | floor)"' <<<"$ev")
      pointer abs $((lx - mx)) $((ly - my)) sleep 100 down sleep 80 up sleep 300
      pointer abs 20 $((mh / 2)) sleep 200
      sleep 0.8
    }
    bar_in_reach() { # title: its frame (the titlebar band above the surface) starts at or below the work area's top
      local _x y _w _h _a
      area_now
      read -r _x y _w _h _a < <(geometry_of "$1")
      say "  $1 surface top ${y:-?}, band $tb, work area top $ay"
      [[ -n ${y:-} ]] && (( y - tb >= ay - 1 ))
    }
    split_members_of() { # address: a member of a Split View Desktop now
      tiling_state | jq -e --arg a "${1#0x}" 'any(.splits[]; .windows | index($a) != null)' >/dev/null 2>&1
    }
    half_of() { # title left|right: that half of the whole output (D42: no menu bar or Dock reservation, one separator of
      # tiling.margin in the middle, on the grid: up to 8 px of rounding; 6e: no band above a member)
      local x y w h _a
      read -r x y w h _a < <(geometry_of "$1")
      say "  $1 at $x,$y ${w}x$h (output $mx,$my ${mw}x$mh, band $stb)"
      near $((y - stb)) "$my" 1 && near $((h + stb)) "$mh" 1 || return 1
      if [[ $2 == left ]]; then
        near "$x" "$mx" 1 && (( x + w <= mx + mw / 2 - m / 2 + 1 && x + w >= mx + mw / 2 - m / 2 - 8 ))
      else
        near $((x + w)) $((mx + mw)) 1 && (( x >= mx + mw / 2 + m / 2 - 1 && x <= mx + mw / 2 + m / 2 + 8 ))
      fi
    }
    fills_output() { # title: the whole output (D43; 6e: no band above a member)
      local x y w h _a
      read -r x y w h _a < <(geometry_of "$1")
      say "  $1 at $x,$y ${w}x$h (output $mx,$my ${mw}x$mh, band $stb)"
      near "$x" "$mx" 1 && near $((y - stb)) "$my" 1 && near "$w" "$mw" 1 && near $((h + stb)) "$mh" 1
    }
    home=$(shown_desktop)
    next=$(($(nestctl workspaces -j | jq '[.[].id, 0] | max') + 1))
    read -r bx by bw bh _ < <(geometry_of tiling-foot)
    mark_events
    split_ipc "$addr" top
    check "split: a side other than left or right is refused (reason invalid)" event_came '.type == "tiling" and .reason == "invalid"'
    check "split: nothing changed" test "$(shown_desktop)" = "$home"
    mark_events
    split_ipc "$addr" left
    check "split: the plugin posts placed" event_came '.type == "tiling" and .reason == "placed"'
    check "split: $out shows a new Desktop with the next free id ($next)" test "$(shown_desktop)" = "$next"
    check "split: the window is on it" test "$(desktop_of "$addr")" = "$next"
    check "split: the reply lists it with the Desktop it came from ($home)" split_listed "$next" "$home"
    check "split: the window takes the left half while its second window is chosen" half_of tiling-foot left
    split_suggestion() {
      local sg
      sg=$(suggestion)
      say "  suggestion: $sg"
      jq -e --arg a "${addr#0x}" --arg b "${addr2#0x}" --arg c "${addr3#0x}" --arg o "$out" \
        '.address == $a and .layout == "left-right" and .output == $o and ([.zones[].zone] == [1])
         and (.windows | index($b) != null and index($c) != null and index($a) == null)' <<<"$sg" >/dev/null
    }
    check "split: the suggestion offers the right half with the windows of the Desktop it came from" split_suggestion
    mark_events
    split_ipc "$addr" right
    check "split: a window of a Split View Desktop is refused (reason invalid)" event_came '.type == "tiling" and .reason == "invalid"'

    arrange "{\"layout\":\"left-right\",\"windows\":[\"$addr2\"],\"zone\":1,\"with\":\"$addr\"}"
    check "split pick: the second window joins the Split View Desktop" test "$(desktop_of "$addr2")" = "$next"
    check "split pick: it takes the right half" half_of tiling-foot2 right
    check "split pick: the first keeps the left half" half_of tiling-foot left
    split_pair() {
      local a b
      a=$(record_of "$addr")
      b=$(record_of "$addr2")
      say "  first: $a; second: $b"
      jq -e -n --argjson a "$a" --argjson b "$b" \
        '$a.layout == "left-right" and $a.zone == 0 and $b.layout == "left-right" and $b.zone == 1 and $b.state == "tiled" and $a.group > 0 and $a.group == $b.group' >/dev/null
    }
    check "split pick: one tile group (the shared edge resizes both)" split_pair
    split_pair_swapped() { # the first window in zone 1, the second in zone 0, one group (step 6b's swap)
      local a b
      a=$(record_of "$addr")
      b=$(record_of "$addr2")
      say "  first: $a; second: $b"
      jq -e -n --argjson a "$a" --argjson b "$b" \
        '$a.layout == "left-right" and $a.zone == 1 and $b.layout == "left-right" and $b.zone == 0 and $a.state == "tiled" and $b.state == "tiled" and $a.group > 0 and $a.group == $b.group' >/dev/null
    }
    check "split pick: the reply lists both members" split_members "$next" "$addr" "$addr2"
    # Step 6b (TL33): the separator (the shared edge between the two members) dragged 80 px, then double-clicked: both back
    # to equal halves, still members.
    if nestctl -j grassfield 2>/dev/null | jq -e '.features | index("tiling-shared-edge")' >/dev/null 2>&1; then
      read -r slx sly slw slh _ < <(geometry_of tiling-foot)
      read -r srx _ _ _ _ < <(geometry_of tiling-foot2)
      shx=$((slx + slw + (srx - slx - slw) / 2 - mx)) shy=$((sly - stb + (slh + stb) / 2 - my))
      say "  separator at $shx,$shy (left member right side $((slx + slw)), right member at $srx)"
      separator_moved() {
        local _x _y w _h _a
        read -r _x _y w _h _a < <(geometry_of tiling-foot)
        say "  left member ${w:-?} wide (was $slw)"
        (( ${w:-0} >= slw + 60 ))
      }
      pointer abs "$shx" "$shy" sleep 300 down drag $((shx + 80)) "$shy" sleep 200 up sleep 400
      check "split separator: dragged 80 px, the left member grew" separator_moved
      mark_events
      pointer abs $((shx + 80)) "$shy" sleep 300 down sleep 40 up sleep 100 down sleep 40 up sleep 500
      check "split separator: a double-click puts the left member back in its half" half_of tiling-foot left
      check "split separator: and the right member in its half" half_of tiling-foot2 right
      check "split separator: the plugin posts resized" event_came '.type == "tiling" and .reason == "resized"'
      check "split separator: both still members" split_members "$next" "$addr" "$addr2"
      pointer abs 20 $((mh / 2)) sleep 200
    else
      say "SKIP: split separator (the plugin does not advertise tiling-shared-edge)"
    fi
    # D50 (integrator review of c7a6b6e, MAJOR 1): an app's own full screen, or a zoom, keeps a member and its half; the other
    # does not fill meanwhile, and the window comes back to its half after.
    for mode in fullscreen maximized; do
      nestctl dispatch "hl.dsp.window.fullscreen({ mode = \"$mode\", window = \"address:$addr2\" })" >>"$log" 2>&1
      sleep 1
      check "split $mode: the other member keeps its half" half_of tiling-foot left
      check "split $mode: both still members" split_members "$next" "$addr" "$addr2"
      nestctl dispatch "hl.dsp.window.fullscreen({ mode = \"$mode\", window = \"address:$addr2\" })" >>"$log" 2>&1
      sleep 1
      check "split $mode ended: the window is back in its half" half_of tiling-foot2 right
      check "split $mode ended: the other still in its half" half_of tiling-foot left
    done
    # D52: a third window opening on the Split View Desktop is no member: the halves stay, also once it closed.
    open_xdg gf-split-third
    if [[ -n $xdg_addr ]]; then
      check "split third: it opened on the Split View Desktop" test "$(desktop_of "$xdg_addr")" = "$next"
      check "split third: no member" split_members "$next" "$addr" "$addr2"
      kill "$xdg_pid" 2>/dev/null
      for _ in $(seq 1 25); do [[ -z $(nestctl clients -j | jq -r --arg a "$xdg_addr" '.[] | select(.address == $a) | .address') ]] && break; sleep 0.2; done
      sleep 0.8
      check "split third: closed, the halves stay" half_of tiling-foot left
      check "split third: the right half too" half_of tiling-foot2 right
    else
      check "split third: the third window opened" false
    fi
    # D46: one of Hyprland's moves (Super+drag) of a member puts it back in its half at the release.
    if declare -F super_drag >/dev/null; then
      super_drag $((mx + mw / 2)) $((my + mh / 2)) 300
      check "split Super+drag: the member is back in its half" half_of tiling-foot left
      check "split Super+drag: still a member" split_members "$next" "$addr" "$addr2"
    else
      say "SKIP: split Super+drag (the step 2 helpers did not run)"
    fi
    mark_events
    tile_ipc "$addr" right
    check "split keys: tiling a member is refused (reason invalid)" event_came '.type == "tiling" and .reason == "invalid"'
    check "split keys: it keeps its half" half_of tiling-foot left
    # Step 6b (D59): a member's titlebar drag released in its own half puts it back there; released over the other half, the
    # two swap halves (macOS), still members of one group; dragged back over the other half, they swap again. Step 6e (D75):
    # by its revealed bar (member_grip, reveal_over: the pointer at the top edge over its half first).
    if read -r gx gy < <(member_grip "$addr"); then
      reveal_over "$gx"
      pointer abs "$gx" "$gy" sleep 200 down drag $((gx + 120)) $((gy + 80)) sleep 300 up sleep 600
      check "split titlebar: released in its own half, back in it" half_of tiling-foot left
      check "split titlebar: the other member did not move" half_of tiling-foot2 right
      mark_events
      reveal_over "$gx"
      pointer abs "$gx" "$gy" sleep 200 down drag $((mw * 3 / 4)) $((mh / 2)) sleep 300 up sleep 800
      check "split swap: the plugin posts placed" event_came '.type == "tiling" and .reason == "placed"'
      check "split swap: the dragged window takes the right half" half_of tiling-foot right
      check "split swap: the other window takes the left half" half_of tiling-foot2 left
      check "split swap: both still members" split_members "$next" "$addr" "$addr2"
      check "split swap: still one tile group" split_pair_swapped
      if read -r gx gy < <(member_grip "$addr"); then
        reveal_over "$gx"
        pointer abs "$gx" "$gy" sleep 200 down drag $((mw / 4)) $((mh / 2)) sleep 300 up sleep 800
      fi
      check "split swap back: the first window in the left half again" half_of tiling-foot left
      check "split swap back: the second in the right half again" half_of tiling-foot2 right
      check "split swap back: zones as at the pick" split_pair
      # A drag over the other half cancelled by a second button (the right one): no swap, back in its half (D59).
      if read -r gx gy < <(member_grip "$addr"); then
        reveal_over "$gx"
        pointer abs "$gx" "$gy" sleep 200 down drag $((mw * 3 / 4)) $((mh / 2)) sleep 300 rdown sleep 100 rup sleep 200 up sleep 800
      fi
      check "split cancelled: a second button ends the drag, back in its half" half_of tiling-foot left
      check "split cancelled: no swap" half_of tiling-foot2 right
      # The drag exemption (integrator PASS on 12e3dd3, MINOR A): the plugin's state read during a member's drag (the shell's
      # fetch does so at any notice) keeps the dragged member's record, and the drop still swaps; then back.
      if read -r gx gy < <(member_grip "$addr"); then
        reveal_over "$gx"
        pointer abs "$gx" "$gy" sleep 200 down drag $((mw * 3 / 4)) $((mh / 2)) sleep 3000 up sleep 200 &
        held_pid=$!
        # The read waits for the drag itself (the window follows the pointer over the other half), not a fixed time (merge
        # note of #56): polled every 50 ms for at most 2.5 s of the 3 s the button stays held there.
        drag_underway() {
          local x _y _w _h _a
          read -r x _y _w _h _a < <(geometry_of tiling-foot)
          (( ${x:-0} > mx + mw / 8 ))
        }
        for _ in $(seq 50); do
          drag_underway && break
          sleep 0.05
        done
        check "split drag read: the dragged window follows the pointer (the drag is on)" drag_underway
        record_mid_drag() {
          local r
          r=$(record_of "$addr")
          say "  during the drag: $r"
          jq -e '.state == "tiled" and .layout == "left-right" and .zone == 0' <<<"$r" >/dev/null
        }
        check "split drag read: a state read during the drag keeps the dragged member's record" record_mid_drag
        check "split drag read: both still members during the drag" split_members "$next" "$addr" "$addr2"
        wait "$held_pid"
        sleep 0.8
        check "split drag read: the drop after it still swaps" half_of tiling-foot right
        check "split drag read: the other window in the left half" half_of tiling-foot2 left
        if read -r gx gy < <(member_grip "$addr"); then
          reveal_over "$gx"
          pointer abs "$gx" "$gy" sleep 200 down drag $((mw / 4)) $((mh / 2)) sleep 300 up sleep 800
        fi
        check "split drag read: swapped back" half_of tiling-foot left
      fi
    else
      check "split titlebar: the first window's grip found" false
    fi
    # Step 6e (TL33, ADR-0036 D74, D75; with tiling-split-titles): the halves fill from the output's top edge (half_of above, no
    # band); the pointer at the top edge over a half reveals that half's bar alone (the plugin's log names the window) and the
    # titlebar-reveal event comes (the menu bar follows); moving across within the bar's band brings the other half's bar and
    # the first goes; below the band both go. A member's drag by its revealed bar with the session locked meanwhile: back in
    # its half at the lock, no swap at the release.
    if ((split_titles)); then
      # Hyprland's in-memory log (the log file is buffered: the review of #99); each Split View bar's change is numbered.
      reveal_mark() { local n; n=$(nestctl rollinglog 2>/dev/null | grep -ao "(reveal [0-9]*)" | tail -n 1 | tr -dc '0-9'); echo "${n:-0}"; }
      reveal_seen() { # pattern mark: a line "PATTERN (reveal N)" with N past mark in the in-memory log now
        local n
        for n in $(nestctl rollinglog 2>/dev/null | grep -ao -- "$1 (reveal [0-9]*)" | sed 's/.*(reveal \([0-9]*\))/\1/'); do
          (( n > $2 )) && return 0
        done
        return 1
      }
      reveal_came() { local _; for _ in $(seq 1 30); do reveal_seen "$1" "$2" && return 0; sleep 0.1; done; return 1; }
      reveal_absent() { ! reveal_seen "$1" "$2"; } # checked once the line it races with came (the log is in order)
      read -r tlx _ tlw _ _ < <(geometry_of tiling-foot)
      read -r trx _ trw _ _ < <(geometry_of tiling-foot2)
      lmid=$((tlx + tlw / 2 - mx)) rmid=$((trx + trw / 2 - mx))
      gapl=$((tlx + tlw - mx)) gapr=$((trx - mx)) bandy=$((split_inset + GF_TB_MID))
      say "  halves: left ends at $gapl, right starts at $gapr (relative to $out); the band at y $bandy"
      lrev="titlebar of Split View window ${addr#0x} revealed" laway="titlebar of Split View window ${addr#0x} away"
      rrev="titlebar of Split View window ${addr2#0x} revealed" raway="titlebar of Split View window ${addr2#0x} away"
      pointer abs "$lmid" $((mh / 2)) sleep 400
      r0=$(reveal_mark)
      mark_events
      pointer abs "$lmid" 0 sleep 500
      check "split titles: the pointer at the top edge over the left half reveals the left member's bar" reveal_came "$lrev" "$r0"
      check "split titles: not the right member's" reveal_absent "$rrev" "$r0"
      check "split titles: the plugin posts titlebar-reveal for $out (the menu bar follows it, D65)" \
        event_came ".type == \"titlebar-reveal\" and .output == \"$out\" and .revealed == true"
      r0=$(reveal_mark)
      pointer abs "$rmid" "$bandy" sleep 500
      check "split titles: moving across within the band brings the right member's bar" reveal_came "$rrev" "$r0"
      check "split titles: and the left member's bar goes" reveal_came "$laway" "$r0"
      r0=$(reveal_mark)
      mark_events
      pointer abs "$rmid" $((mh / 2)) sleep 500
      check "split titles: below the band the right member's bar goes too" reveal_came "$raway" "$r0"
      check "split titles: the plugin posts titlebar-reveal false for $out" \
        event_came ".type == \"titlebar-reveal\" and .output == \"$out\" and .revealed == false"
      r0=$(reveal_mark)
      pointer abs "$rmid" "$bandy" sleep 500
      check "split titles: coming from below to where the bar would be reveals nothing" reveal_absent "$rrev" "$r0"
      # The review of #99 (MAJOR): the band walked across the gap between the halves in 4 px steps, as a hand moves: the left
      # bar stays while the pointer is in the gap, and goes only when the right half's bar comes.
      if (( gapr > gapl )); then
        pointer abs "$lmid" $((mh / 2)) sleep 200 abs $((gapl - 16)) 0 sleep 400
        walk() { local x seq=() ; for ((x = $1; x <= $2; x += 4)); do seq+=(abs "$x" "$bandy" sleep 40); done; pointer "${seq[@]}" sleep 300; }
        r0=$(reveal_mark)
        walk $((gapl - 12)) $(((gapl + gapr) / 2))
        check "split gap walk: in the gap the left member's bar stays" reveal_absent "$laway" "$r0"
        check "split gap walk: and the right one has not come yet" reveal_absent "$rrev" "$r0"
        walk $(((gapl + gapr) / 2 + 4)) $((gapr + 16))
        check "split gap walk: over the right half the right member's bar comes" reveal_came "$rrev" "$r0"
        check "split gap walk: and the left one goes" reveal_came "$laway" "$r0"
      else
        say "  split gap walk: no gap between the halves on $out (margins off): skipped"
      fi
      pointer abs 20 $((mh / 2)) sleep 200
      # D75: the session locked during the revealed bar's drag over the other half: the member back in its half at the lock,
      # the release under the lock swaps nothing.
      if read -r gx gy < <(member_grip "$addr"); then
        reveal_over "$gx"
        pointer abs "$gx" "$gy" sleep 200 down drag $((mw * 3 / 4)) $((mh / 2)) sleep 9000 up sleep 200 &
        held_pid=$!
        drag_on() { local x _y _w _h _a; read -r x _y _w _h _a < <(geometry_of tiling-foot); (( ${x:-0} > mx + mw / 8 )); }
        for _ in $(seq 50); do drag_on && break; sleep 0.05; done
        check "split titles drag: the member follows the pointer by its revealed bar" drag_on
        if lock_session; then
          sleep 0.5
          check "split titles drag: at the lock the member is back in its half" half_of tiling-foot left
          wait "$held_pid"
          sleep 0.8
          check "split titles drag: the release under the lock swapped nothing" half_of tiling-foot2 right
          check "split titles drag: still members" split_members "$next" "$addr" "$addr2"
          unlock_session || check "split titles drag: the session unlocked" false
        else
          wait "$held_pid"
          check "split titles drag: the foreign locker locked the session" false
          unlock_session >/dev/null 2>&1
        fi
        sleep 0.5
        check "split titles drag: after the unlock both in their halves" half_of tiling-foot left
      else
        check "split titles: the first window's revealed grip found" false
      fi
      pointer abs 20 $((mh / 2)) sleep 200
    else
      say "SKIP: step 6e split titles (the plugin does not advertise tiling-split-titles)"
    fi

    if lock_session; then
      mark_events
      unsplit_ipc "$addr"
      check "split locked: unsplit is refused (reason locked)" event_came '.type == "tiling" and .reason == "locked"'
      check "split locked: the window stays on the Split View Desktop" test "$(desktop_of "$addr")" = "$next"
      if nestctl -j grassfield 2>/dev/null | jq -e '.features | index("tiling-split-rows")' >/dev/null 2>&1; then
        mark_events
        nestctl dispatch "hl.plugin.grassfield.unsplit(\"$addr\", \"replace\")" >>"$log" 2>&1
        sleep 1
        check "split locked: Replace Tiled Window is refused too (reason locked, D71)" event_came '.type == "tiling" and .reason == "locked"'
        check "split locked: still on the Split View Desktop" test "$(desktop_of "$addr")" = "$next"
      fi
      mark_events
      split_ipc "$addr3" left
      check "split locked: split is refused (reason locked)" event_came '.type == "tiling" and .reason == "locked"'
    else
      check "split locked: the foreign locker holds the session lock (${locked:-no answer})" false
    fi
    check "split locked: released, Hyprland reports the session unlocked" unlock_session
    sleep 0.5

    # D44: Exit Full Screen sends that window back; the other stays and fills the Split View Desktop.
    mark_events
    unsplit_ipc "$addr"
    check "unsplit: $out shows the Desktop it came from again" test "$(shown_desktop)" = "$home"
    check "unsplit: the window is back on it" test "$(desktop_of "$addr")" = "$home"
    check "unsplit: at its box from before" box_of tiling-foot "$bx" "$by" "$bw" "$bh"
    check "unsplit: no tile record left" test "$(record_of "$addr")" = null
    check "unsplit: the other window stays on the Split View Desktop" test "$(desktop_of "$addr2")" = "$next"
    check "unsplit: and fills it alone" fills_output tiling-foot2
    check "unsplit: the Split View Desktop is still listed" split_listed "$next" "$home"
    # D43: the Split View Desktop emptied while shown goes back to the Desktop it came from, and ends.
    nestctl dispatch "hl.dsp.focus({ workspace = \"$next\" })" >>"$log" 2>&1
    sleep 0.8
    check "split empty: shown again" test "$(shown_desktop)" = "$next"
    move_off "$addr2" "$home"
    check "split empty: its last window moved off, $out goes back to the Desktop it came from" test "$(shown_desktop)" = "$home"
    if ((split_titles)); then
      # The review of #99: a member moved off by a key gets its titlebar back below the menu bar (its surface was at the top).
      check "split empty: the window moved off has its titlebar in reach" bar_in_reach tiling-foot2
    fi
    check "split empty: the reply no longer lists it" split_gone "$next" "$home"
    tile_ipc "$addr2" previous

    # D43: one of the two leaving (minimized here) leaves the other filling the Split View Desktop.
    next2=$(($(nestctl workspaces -j | jq '[.[].id, 0] | max') + 1))
    split_ipc "$addr3" right
    check "split leave: the third window makes Split View Desktop $next2" test "$(desktop_of "$addr3")" = "$next2"
    check "split leave: in the right half" half_of tiling-foot3 right
    arrange "{\"layout\":\"left-right\",\"windows\":[\"$addr\"],\"zone\":0,\"with\":\"$addr3\"}"
    check "split leave: the first window picked into the left half" half_of tiling-foot left
    move_off "$addr" special:minimized
    check "split leave: the other window fills the Split View Desktop" fills_output tiling-foot3
    move_off "$addr" "$home"
    if ((split_titles)); then
      check "split leave: back from special:minimized, its titlebar in reach" bar_in_reach tiling-foot
    fi
    # D49: the green button of a member leaves the Split View (macOS exits full screen), here its last one, zoomed by a key
    # first (re-review of e5bd9d2: it went home still zoomed).
    nestctl dispatch "hl.dsp.window.fullscreen({ mode = \"maximized\", window = \"address:$addr3\" })" >>"$log" 2>&1
    sleep 1
    green_click "$addr3"
    check "split green: the member's zoom light: the Desktop it came from shown" test "$(shown_desktop)" = "$home"
    check "split green: the window is back on it" test "$(desktop_of "$addr3")" = "$home"
    check "split green: it was not zoomed" test "$(nestctl clients -j | jq -r --arg a "$addr3" '.[] | select(.address == $a) | .fullscreen')" = 0
    check "split leave: the Split View Desktop ended" split_gone "$next2" "$home"
    tile_ipc "$addr" previous

    # Step 6d (ADR-0036 D71): unsplit's second argument, with the plugin's tiling-split-rows. An unknown `how` is refused;
    # Replace Tiled Window sends the member home without showing it, the other keeps its half and waits, the suggestion of the
    # vacated half never offering the window replaced; a pick fills it again; Make Window Full Screen sends a member home in
    # full screen, the other filling; Replace with one member is refused.
    if nestctl -j grassfield 2>/dev/null | jq -e '.features | index("tiling-split-rows")' >/dev/null 2>&1; then
      unsplit_how() { nestctl dispatch "hl.plugin.grassfield.unsplit(\"$1\", \"$2\")" >>"$log" 2>&1; sleep 1; }
      waiting_of() { tiling_state | jq -r --argjson w "$1" '[.splits[] | select(.workspace == $w) | .waiting][0] // "none"'; }
      fs_state() { nestctl clients -j | jq -r --arg a "$1" '.[] | select(.address == $a) | .fullscreen'; }
      next7=$(($(nestctl workspaces -j | jq '[.[].id, 0] | max') + 1))
      split_ipc "$addr3" right
      arrange "{\"layout\":\"left-right\",\"windows\":[\"$addr\"],\"zone\":0,\"with\":\"$addr3\"}"
      check "split rows: two members" split_members "$next7" "$addr3" "$addr"
      mark_events
      unsplit_how "$addr" zoom
      check "split rows: an unknown how is refused (reason invalid)" event_came '.type == "tiling" and .reason == "invalid"'
      check "split rows: nothing moved" split_members "$next7" "$addr3" "$addr"
      unsplit_how "$addr" replace
      check "split replace: the window replaced is back on its Desktop" test "$(desktop_of "$addr")" = "$home"
      check "split replace: the Split View Desktop stays shown" test "$(shown_desktop)" = "$next7"
      check "split replace: the other member keeps its half" half_of tiling-foot3 right
      check "split replace: one member, waiting again" split_members "$next7" "$addr3"
      check "split replace: its half waits for a window" test "$(waiting_of "$next7")" = true
      replace_offer() { # the suggestion fills the vacated left half for the member kept, never offering the window replaced
        local sg
        sg=$(suggestion)
        say "  suggestion: $sg"
        jq -e --arg kept "${addr3#0x}" --arg gone "${addr#0x}" '.address == $kept and .zones[0].zone == 0 and (.windows | index($gone) | not)' <<<"$sg" >/dev/null
      }
      check "split replace: the suggestion offers the vacated half, never the window replaced" replace_offer
      arrange "{\"layout\":\"left-right\",\"windows\":[\"$addr2\"],\"zone\":0,\"with\":\"$addr3\"}"
      check "split replace: a pick fills the vacated half" split_members "$next7" "$addr3" "$addr2"
      check "split replace: in the left half" half_of tiling-foot2 left
      unsplit_how "$addr2" fullscreen
      check "split full screen: the member is back on its Desktop" test "$(desktop_of "$addr2")" = "$home"
      check "split full screen: in full screen there (D71)" test "$(fs_state "$addr2")" = 2
      check "split full screen: the other member fills the Split View Desktop" fills_output tiling-foot3
      fs_clear "$addr2" || say "  split full screen: the window was still in full screen"
      mark_events
      unsplit_how "$addr3" replace
      check "split replace alone: refused with one member (reason invalid)" event_came '.type == "tiling" and .reason == "invalid"'
      check "split replace alone: still the member" split_members "$next7" "$addr3"
      unsplit_ipc "$addr3"
      check "split rows: the Split View Desktop ended" split_gone "$next7" "$home"
      tile_ipc "$addr" previous
      tile_ipc "$addr2" previous
      tile_ipc "$addr3" previous
    else
      say "SKIP: step 6d rows (the plugin does not advertise tiling-split-rows)"
    fi

    # D51, D55 (re-review of e5bd9d2: MAJOR A and the glue mutants G4, G5): nothing of a Split View changes behind the lock,
    # and it settles at the unlock. An xdgact window is the first member here (it is closed while locked).
    addr_box() { nestctl clients -j | jq -r --arg a "$1" '.[] | select(.address == $a) | "\(.at[0]) \(.at[1]) \(.size[0]) \(.size[1])"'; }
    fills_addr() { # address: the whole output (with the plugin's titlebar band above the surface, or none: client chrome)
      local x y w h
      read -r x y w h < <(addr_box "$1")
      say "  $1 at ${x:-?},${y:-?} ${w:-?}x${h:-?} (output $mx,$my ${mw}x$mh, band $tb or none)"
      [[ -n ${h:-} ]] && near "$x" "$mx" 1 && near "$w" "$mw" 1 && { { near $((y - tb)) "$my" 1 && near $((h + tb)) "$mh" 1; } || { near "$y" "$my" 1 && near "$h" "$mh" 1; }; }
    }
    open_xdg gf-split-lock
    if [[ -n $xdg_addr ]]; then
      next3=$(($(nestctl workspaces -j | jq '[.[].id, 0] | max') + 1))
      split_ipc "$xdg_addr" left
      check "split lock: the xdgact window makes Split View Desktop $next3" test "$(desktop_of "$xdg_addr")" = "$next3"
      arrange "{\"layout\":\"left-right\",\"windows\":[\"$addr2\"],\"zone\":1,\"with\":\"$xdg_addr\"}"
      check "split lock: the second window picked" split_members "$next3" "$xdg_addr" "$addr2"
      # D49 with two members: the green button sends that window back, the other fills.
      green_click "$addr2"
      check "split green with two members: the window is back on its Desktop" test "$(desktop_of "$addr2")" = "$home"
      check "split green with two members: the other fills alone" fills_addr "$xdg_addr"
      nestctl dispatch "hl.dsp.focus({ workspace = \"$next3\" })" >>"$log" 2>&1
      sleep 0.8
      # D55: its last member closed while locked: the Desktop stays shown and listed until the unlock (G5), then ends and the
      # output goes back home (the unlock listener, G4).
      if lock_session; then
        kill "$xdg_pid" 2>/dev/null
        sleep 1.5
        check "split locked close: no Desktop switch behind the lock" test "$(shown_desktop)" = "$next3"
        check "split locked close: still listed while locked" split_listed "$next3" "$home"
      else
        check "split locked close: the foreign locker holds the session lock (${locked:-no answer})" false
      fi
      check "split locked close: released, Hyprland reports the session unlocked" unlock_session
      sleep 1.5
      check "split locked close: at the unlock, the Desktop it came from shown" test "$(shown_desktop)" = "$home"
      check "split locked close: at the unlock, it ended" split_gone "$next3" "$home"
      # MAJOR A: lock with a Split View still waiting for its second window: the lock ends its picker; nothing moves while
      # locked; at the unlock the plugin fills the member itself.
      tile_ipc "$addr2" previous
      next4=$(($(nestctl workspaces -j | jq '[.[].id, 0] | max') + 1))
      split_ipc "$addr3" left
      waiting_now() { tiling_state | jq -e --argjson w "$next4" 'any(.splits[]; .workspace == $w and .waiting == true)' >/dev/null; }
      check "split locked picker: waiting for its second window" waiting_now
      if lock_session; then
        sleep 1
        check "split locked picker: nothing moves behind the lock" half_of tiling-foot3 left
      else
        check "split locked picker: the foreign locker holds the session lock (${locked:-no answer})" false
      fi
      check "split locked picker: released, Hyprland reports the session unlocked" unlock_session
      sleep 1.5
      check "split locked picker: at the unlock, the member fills its Desktop" fills_output tiling-foot3
      unsplit_ipc "$addr3"
      check "split locked picker: Exit Full Screen ends it" split_gone "$next4" "$home"
      tile_ipc "$addr3" previous
    else
      check "split lock: the xdgact window opened" false
    fi

    # D57 (integrator nested pass of 1ee992e, MAJOR C): a window whose minimum width is wider than half of the output does not
    # fit a Split View half: the popover's event says so (the popover greys Left and Right of Screen), split refuses it, the
    # picker of another Split View does not offer it, and a pick of it there is refused; an ordinary window fits.
    open_xdg gf-split-wide $((mw / 2 + 200))
    if [[ -n $xdg_addr ]]; then
      hover_open_of() { # address jq-condition: tile_popover posts open for that window, the condition holding on its event
        mark_events
        nestctl dispatch "hl.plugin.grassfield.tile_popover(\"$1\")" >>"$log" 2>&1
        event_came ".type == \"tile-hover\" and .address == \"${1#0x}\" and .state == \"open\" and $2"
        local ok=$?
        say "  event: $last_event"
        close_shell_popup "split wide"
        return $ok
      }
      check "split wide: its event says it does not fit a half (tileable, splittable false)" hover_open_of "$xdg_addr" '.tileable == true and .splittable == false'
      check "split wide: an ordinary window fits (splittable true)" hover_open_of "$addr" '.splittable == true'
      mark_events
      split_ipc "$xdg_addr" left
      check "split wide: split is refused (reason invalid)" event_came '.type == "tiling" and .reason == "invalid"'
      check "split wide: $out still shows the Desktop it was on" test "$(shown_desktop)" = "$home"
      check "split wide: the window stays there" test "$(desktop_of "$xdg_addr")" = "$home"
      next6=$(($(nestctl workspaces -j | jq '[.[].id, 0] | max') + 1))
      split_ipc "$addr" left
      wide_not_offered() {
        local sg
        sg=$(suggestion)
        say "  suggestion: $sg"
        jq -e --arg w "${xdg_addr#0x}" --arg b "${addr2#0x}" '(.windows | index($w) == null and index($b) != null)' <<<"$sg" >/dev/null
      }
      check "split wide: the picker of another Split View does not offer it" wide_not_offered
      mark_events
      arrange "{\"layout\":\"left-right\",\"windows\":[\"$xdg_addr\"],\"zone\":1,\"with\":\"$addr\"}"
      check "split wide: a pick of it into the other half is refused (reason invalid)" event_came '.type == "tiling" and .reason == "invalid"'
      check "split wide: it stays on its Desktop" test "$(desktop_of "$xdg_addr")" = "$home"
      unsplit_ipc "$addr"
      check "split wide: Exit Full Screen ends that Split View" split_gone "$next6" "$home"
      tile_ipc "$addr" previous
      kill "$xdg_pid" 2>/dev/null
      sleep 0.5
    else
      check "split wide: the xdgact window opened" false
    fi

    # Integrator nested pass of 1ee992e, with the shell running: a Split View the shell did not start shows its picker
    # (MAJOR B, D48 amended) with its first window selected, so a first Return picks it (MINOR D), and the window picked has
    # the keyboard after (MINOR E, D58); the tiling popover opens on a member and its Exit Full Screen runs from the keyboard,
    # and no overlay stays mapped after it (BLOCKER A).
    open_kind() { timeout 5 "$root/tests/visual/ipc.sh" menubar openKind 2>>"$log"; }
    overlay_gone() { ! shell_popup_open; }
    active_is() { # address
      local a
      a=$(nestctl activewindow -j | jq -r '.address')
      say "  active window: $a (want $1)"
      [[ $a == "$1" ]]
    }
    if kind=$(open_kind) && [[ $kind != refused ]]; then
      split_loops_before=$(shell_loops)
      close_shell_popup "split shell"
      next5=$(($(nestctl workspaces -j | jq '[.[].id, 0] | max') + 1))
      split_ipc "$addr3" left
      first=$(suggestion | jq -r '.windows[0] // empty')
      say "  first window offered: ${first:-none}"
      check "split shell: the shell shows the picker of a Split View it did not start" test "$(open_kind)" = "tilingSuggest@$out"
      check "split shell: its member is not filled meanwhile" half_of tiling-foot3 left
      keys -k Return
      sleep 1.5
      check "split shell: a first Return picks the first window offered" split_members "$next5" "$addr3" "0x$first"
      check "split shell: the picker closed" test -z "$(open_kind)"
      sleep 1
      check "split shell: the window picked has the keyboard" active_is "0x$first"
      mark_events
      nestctl dispatch "hl.plugin.grassfield.tile_popover(\"$addr3\")" >>"$log" 2>&1
      sleep 1
      check "split shell popover: the tiling popover opens on a member" test "$(open_kind)" = "tiling@$out"
      keys -k Escape
      wait_popup_closed || true
      check "split shell popover: Esc closes it" test -z "$(open_kind)"
      check "split shell popover: no overlay left mapped" overlay_gone
      nestctl dispatch "hl.plugin.grassfield.tile_popover(\"$addr3\")" >>"$log" 2>&1
      sleep 1
      check "split shell popover: open again" test "$(open_kind)" = "tiling@$out"
      keys -k Down
      keys -k Return
      sleep 1.5
      check "split shell popover: its Exit Full Screen sends the member back to the Desktop it came from" test "$(desktop_of "$addr3")" = "$home"
      check "split shell popover: the popover closed" test -z "$(open_kind)"
      check "split shell popover: no overlay left mapped" overlay_gone
      check "split shell popover: the other member fills the Split View Desktop" fills_addr "0x$first"
      # D64 on a member (integrator review of 7096305, MAJOR 1): its light lies under the menu bar's strip (the bar is away on
      # a Split View Desktop); clicked under its open popover, the member leaves the Split View and no app menu opens.
      close_shell_popup "split green under popover"
      # The other member's Exit Full Screen just showed the home Desktop: the member's Split View Desktop is shown again first
      # (integrator re-review of 67800eb, A: the click landed on the menu bar of the home Desktop).
      nestctl dispatch "hl.dsp.focus({ window = 'address:0x$first' })" >>"$log" 2>&1
      sleep 1
      check "split green under popover: the member's Split View Desktop is shown" test "$(shown_desktop)" = "$next5"
      mark_events
      nestctl dispatch "hl.plugin.grassfield.tile_popover(\"0x$first\")" >>"$log" 2>&1
      if [[ $(shown_desktop) == "$next5" ]] && event_came ".type == \"tile-hover\" and .address == \"$first\" and .state == \"open\""; then
        read -r slx sly < <(jq -r '"\((.x + .w / 2) | floor) \((.y + .h / 2) | floor)"' <<<"$last_event")
        say "  member's light at $slx,$sly"
        if wait_popup_open && [[ $(open_kind) == "tiling@$out" ]]; then
          pointer abs $((slx - mx)) $((sly - my)) sleep 100 down sleep 80 up sleep 200 abs 20 $((mh / 2)) sleep 1200
          check "split green under popover: the member leaves the Split View (D64)" test "$(desktop_of "0x$first")" = "$home"
          check "split green under popover: no app menu opened, the popover closed" test -z "$(open_kind)"
          check "split green under popover: no overlay left mapped" overlay_gone
        else
          check "split green under popover: the member's tiling popover showed before the click (openKind '$(open_kind)')" false
        fi
      else
        check "split green under popover: tile_popover posts open for the member on its shown Split View Desktop" false
      fi
      split_listed "$next5" "$home" >/dev/null 2>&1 && unsplit_ipc "0x$first"
      close_shell_popup "split green under popover end"
      check "split shell: ended" split_gone "$next5" "$home"
      tile_ipc "$addr3" previous
      tile_ipc "0x$first" previous
      # Step 6d (D71) with the shell: Replace Tiled Window from a member's popover (its third row, by the keys): the member goes
      # home, the Split View Desktop stays shown with the picker of the vacated half (D48's adoption), and a Return picks the
      # first window offered, never the one replaced.
      if nestctl -j grassfield 2>/dev/null | jq -e '.features | index("tiling-split-rows")' >/dev/null 2>&1; then
        close_shell_popup "split replace shell"
        next8=$(($(nestctl workspaces -j | jq '[.[].id, 0] | max') + 1))
        split_ipc "$addr3" left
        keys -k Return
        sleep 1.5
        second8=$(tiling_state | jq -r --argjson w "$next8" '[.splits[] | select(.workspace == $w) | .windows[1]][0] // empty')
        check "split replace shell: a Split View Desktop with two members ($addr3, 0x${second8:-none})" test -n "$second8"
        close_shell_popup "split replace shell picker"
        nestctl dispatch "hl.plugin.grassfield.tile_popover(\"$addr3\")" >>"$log" 2>&1
        if wait_popup_open && [[ $(open_kind) == "tiling@$out" ]]; then
          keys -k Down
          keys -k Down
          keys -k Down
          keys -k Return
          picker_shown() {
            local _
            for _ in $(seq 1 40); do
              [[ $(open_kind) == "tilingSuggest@$out" ]] && return 0
              sleep 0.1
            done
            return 1
          }
          check "split replace shell: the replaced member is back on its Desktop" test "$(desktop_of "$addr3")" = "$home"
          check "split replace shell: the Split View Desktop stays shown" test "$(shown_desktop)" = "$next8"
          check "split replace shell: the picker of the vacated half shows" picker_shown
          offered8=$(suggestion | jq -r '.windows[0] // empty')
          replaced_not_offered() { ! suggestion | jq -e --arg a "${addr3#0x}" '.windows | index($a)' >/dev/null; }
          check "split replace shell: the window replaced is never offered" replaced_not_offered
          keys -k Return
          sleep 1.5
          check "split replace shell: a Return picks the first window offered" split_members "$next8" "0x$second8" "0x$offered8"
        else
          check "split replace shell: the member's tiling popover showed (openKind '$(open_kind)')" false
        fi
        close_shell_popup "split replace shell end"
        for m8 in $(tiling_state | jq -r --argjson w "$next8" '[.splits[] | select(.workspace == $w) | .windows[]][]? // empty'); do
          unsplit_ipc "0x$m8"
        done
        check "split replace shell: ended" split_gone "$next8" "$home"
        tile_ipc "$addr3" previous
        # The follow-up of #78 (D72): the Overview's own drop path (dev hook overview dropProbe, OverviewWindow.dropWindow)
        # refuses a window dropped on a Split View Desktop and a member dropped on another Desktop; nothing moves.
        ov() { timeout 5 "$root/tests/visual/ipc.sh" overview "$@" 2>>"$log"; }
        next9=$(($(nestctl workspaces -j | jq '[.[].id, 0] | max') + 1))
        split_ipc "$addr3" left
        keys -k Return
        sleep 1.5
        close_shell_popup "overview drop picker"
        # The window dropped is one the picker did not take (the review of #99: its Return picked $addr, whose drop was then
        # refused as a member's and never as a window dropped onto the Split View Desktop).
        outsider=""
        for cand in "$addr" "$addr2"; do
          if [[ $(desktop_of "$cand") == "$home" ]] && ! tiling_state | jq -e --arg a "${cand#0x}" 'any(.splits[]; .windows | index($a) != null)' >/dev/null 2>&1; then
            outsider=$cand
            break
          fi
        done
        if [[ $(desktop_of "$addr3") == "$next9" && -n $outsider ]]; then
          nestctl dispatch "hl.dsp.focus({ window = 'address:$outsider' })" >>"$log" 2>&1
          sleep 1
          ov open >/dev/null
          sleep 1.5
          check "overview drop: a window dropped on the Split View Desktop is refused" test "$(ov dropProbe "$outsider" "$next9")" = refused
          check "overview drop: it stays on its Desktop" test "$(desktop_of "$outsider")" = "$home"
          ov close >/dev/null
          sleep 1
          nestctl dispatch "hl.dsp.focus({ window = 'address:$addr3' })" >>"$log" 2>&1
          sleep 1
          ov open >/dev/null
          sleep 1.5
          check "overview drop: a member dropped on another Desktop is refused" test "$(ov dropProbe "$addr3" "$home")" = refused
          check "overview drop: it stays in its half" test "$(desktop_of "$addr3")" = "$next9"
          ov close >/dev/null
          sleep 1
        else
          check "overview drop: the Split View Desktop $next9 was made for $addr3, a window left on Desktop $home (${outsider:-none})" false
        fi
        close_shell_popup "overview drop end"
        for m9 in $(tiling_state | jq -r --argjson w "$next9" '[.splits[] | select(.workspace == $w) | .windows[]][]? // empty'); do
          unsplit_ipc "0x$m9"
        done
        check "overview drop: the Split View ended" split_gone "$next9" "$home"
        tile_ipc "$addr3" previous
      fi
      surfaces_state
      split_loops_after=$(shell_loops)
      check "split shell: the picker and the popover log no binding loop (${split_loops_before} before, ${split_loops_after} after)" \
        test "$split_loops_after" = "$split_loops_before"
    else
      say "SKIP: split shell cases (no nested shell answers tests/visual/ipc.sh: run them with the shell)"
    fi

    # Integrator, from an owner report on #56 (stuck in full screen on rc1-7): a full-screen window's tiling popover opened by
    # resting on the revealed bar's zoom light, 4 times: the popup is the tiling popover, closing it leaves no overlay mapped,
    # the zoom light then leaves full screen, and the shell logs no binding loop meanwhile.
    if kind=$(open_kind) && [[ $kind != refused ]]; then
      fs_inset=$(nestctl layers -j 2>/dev/null | jq -r --arg o "$out" '[.[$o].levels[][]? | select(.namespace == "grassfield-menubar") | .h] | max // 0')
      [[ $fs_inset =~ ^[0-9]+$ ]] || fs_inset=0
      fs_bar_y=$((fs_inset + GF_TB_MID))
      fs_rest=$(( ${hover_delay:-$(jq -r '.tiling.hoverDelay.value' "$root/ui/tokens/tokens.json")} + 700 ))
      fs_of() { nestctl clients -j | jq -r --arg a "$1" '.[] | select(.address == $a) | .fullscreen'; }
      fs_reveal() { pointer abs $((mw / 2)) $((mh / 2)) sleep 100 abs $((mw / 2)) 0 sleep 300; }
      loops_before=$(shell_loops)
      close_shell_popup "full-screen popover"
      for round in 1 2 3 4; do
        nestctl dispatch "hl.dsp.window.fullscreen({ mode = \"fullscreen\", window = \"address:$addr\" })" >>"$log" 2>&1
        sleep 1
        check "full-screen popover $round: the window is in full screen" test "$(fs_of "$addr")" = 2
        if ((round == 1)); then
          # D61: Super+M (the shell's windows minimize, as the key binding) does nothing to a window in full screen.
          timeout 5 "$root/tests/visual/ipc.sh" windows minimize >>"$log" 2>&1
          sleep 1
          check "full-screen popover: Super+M leaves the window in full screen" test "$(fs_of "$addr")" = 2
          check "full-screen popover: and not minimized" test "$(nestctl clients -j | jq -r --arg a "$addr" '.[] | select(.address == $a) | .workspace.name')" != special:minimized
        fi
        fs_reveal
        pointer abs "$GF_TB_ZOOM_X" "$fs_bar_y" sleep "$fs_rest"
        check "full-screen popover $round: resting on the revealed zoom light opens the tiling popover" test "$(open_kind)" = "tiling@$out"
        keys -k Escape
        wait_popup_closed || true
        check "full-screen popover $round: Esc closes it" test -z "$(open_kind)"
        check "full-screen popover $round: no overlay left mapped" overlay_gone
        fs_reveal
        pointer abs "$GF_TB_ZOOM_X" "$fs_bar_y" sleep 150 click sleep 800
        check "full-screen popover $round: the zoom light leaves full screen" test "$(fs_of "$addr")" = 0
        pointer abs 20 $((mh / 2)) sleep 200
        close_shell_popup "full-screen popover $round"
      done
      # Step 6c (ADR-0036 D64-D66; the integrator's D62 notes on #56): in full screen the menu bar comes and goes with the
      # revealed titlebar (the plugin's titlebar-reveal event), the Dock sits on the overlay layer (its edge reveals it), and
      # a click on the green light under its open popover runs the light. Then the same click off full screen zooms.
      bar_state() { timeout 5 "$root/tests/visual/ipc.sh" menubar autohide "$out" 2>>"$log"; }
      bar_with() { # jq filter on the menu bar's auto-hide state, waited for up to 2 s
        local st _
        for _ in $(seq 1 20); do
          st=$(bar_state)
          jq -e "$1" <<<"$st" >/dev/null 2>&1 && return 0
          sleep 0.1
        done
        say "  menu bar: $st"
        return 1
      }
      dock_level() { nestctl layers -j 2>/dev/null | jq -r --arg o "$out" '[.[$o].levels | to_entries[] | select(any(.value[]; .namespace == "grassfield-dock")) | .key][0] // "none"'; }
      nestctl dispatch "hl.dsp.window.fullscreen({ mode = \"fullscreen\", window = \"address:$addr\" })" >>"$log" 2>&1
      sleep 1
      check "full screen 6c: the window is in full screen" test "$(fs_of "$addr")" = 2
      check "full screen 6c: the Dock sits on the overlay layer (D66)" test "$(dock_level)" = 3
      check "full screen 6c: the menu bar is away" bar_with '.hides == true and .state == "hidden"'
      mark_events
      fs_reveal
      check "full screen 6c: the plugin says the titlebar is revealed (D65)" event_came ".type == \"titlebar-reveal\" and .output == \"$out\" and .revealed == true"
      check "full screen 6c: the menu bar is in view with it" bar_with '.titlebarRevealed == true and .away == false and (.state == "shown" or .state == "revealing")'
      pointer abs $((mw / 2)) $((fs_bar_y + 4)) sleep 1000
      check "full screen 6c: the pointer on the titlebar keeps the menu bar in view" bar_with '.titlebarRevealed == true and .state == "shown"'
      mark_events
      pointer abs $((mw / 2)) $((mh / 2)) sleep 300
      check "full screen 6c: the titlebar away, the plugin says so" event_came ".type == \"titlebar-reveal\" and .output == \"$out\" and .revealed == false"
      check "full screen 6c: the menu bar left with it" bar_with '.titlebarRevealed == false and .state == "hidden"'
      fs_reveal
      pointer abs "$GF_TB_ZOOM_X" "$fs_bar_y" sleep "$fs_rest"
      check "full screen 6c: resting on the revealed zoom light opens the tiling popover" test "$(open_kind)" = "tiling@$out"
      # The pointer leaves the light at once: resting on the restored window's light, the hover opened the popover again before
      # the checks (integrator re-review of 29db357, MINOR 2).
      pointer abs "$GF_TB_ZOOM_X" "$fs_bar_y" sleep 150 click sleep 100 abs 20 $((mh / 2)) sleep 700
      check "full screen 6c: a click on the zoom light under its open popover leaves full screen (D64)" test "$(fs_of "$addr")" = 0
      check "full screen 6c: the popover closed" test -z "$(open_kind)"
      check "full screen 6c: no overlay left mapped" overlay_gone
      check "full screen 6c: the Dock is back on the top layer" test "$(dock_level)" = 2
      pointer abs 20 $((mh / 2)) sleep 200
      close_shell_popup "full screen 6c"
      fs_clear "$addr" || say "  full screen 6c: the window was still zoomed or in full screen"
      nestctl dispatch "hl.plugin.grassfield.tile(\"$addr\", \"previous\")" >>"$log" 2>&1 # untiled: its zoom fills (ADR-0036 D78)
      sleep 0.8
      mark_events
      nestctl dispatch "hl.plugin.grassfield.tile_popover(\"$addr\")" >>"$log" 2>&1
      if event_came ".type == \"tile-hover\" and .address == \"${addr#0x}\" and .state == \"open\""; then
        read -r glx gly < <(jq -r '"\((.x + .w / 2) | floor) \((.y + .h / 2) | floor)"' <<<"$last_event")
        # Only once the popover shows: a popover mapping mid-click cancels the plugin's gesture and nothing zooms (integrator
        # re-review of 67800eb, C).
        if wait_popup_open && [[ $(open_kind) == "tiling@$out" ]]; then
          pointer abs $((glx - mx)) $((gly - my)) sleep 100 down sleep 80 up sleep 200 abs 20 $((mh / 2)) sleep 600
          check "green under popover: a click on the zoom light under its open popover zooms the window (D64; Fill with zoom-fill, D78)" zoomed "$addr"
          check "green under popover: the popover closed" test -z "$(open_kind)"
          check "green under popover: no overlay left mapped" overlay_gone
        else
          check "green under popover: the tiling popover showed before the click (openKind '$(open_kind)')" false
        fi
      else
        check "green under popover: tile_popover posts open" false
      fi
      close_shell_popup "green under popover"
      check "green under popover: the window out of zoom and full screen again" fs_clear "$addr"
      loops_after=$(shell_loops)
      check "full-screen popover: no binding loop in the shell's log (${loops_before} before, ${loops_after} after)" test "$loops_after" = "$loops_before"
      tile_ipc "$addr" previous
    else
      say "SKIP: full-screen popover cases (no nested shell answers tests/visual/ipc.sh)"
    fi
  else
    say "SKIP: step 6a cases (the plugin does not advertise tiling-split)"
  fi

  tile_ipc "$addr3" previous
  free_foot
  kill "$foot3_pid" 2>/dev/null
  # The first window is back under the pointer step 3 left on its zoom light: the pointer goes to the wallpaper, left of
  # every window, and a popover the hover opened meanwhile closes, before the C1 cases.
  pointer abs 20 $((mh / 2)) sleep 200
  close_shell_popup "step 4a end"
  sleep 0.5
else
  say "SKIP: step 4a cases (the plugin does not advertise tiling-layouts, or the second window is missing)"
fi

# Step 6c (ADR-0036 D67; integrator nested pass of 12e3dd3: after an unplug a window sat at x = -2919, off every output): a
# headless output is made and the window placed on its area while its Desktop stays GF-REF's (Hyprland then leaves it where
# it is when that output goes away: it moves only the removed output's Desktops). The output removed, the plugin gathers it:
# centred on GF-REF's work area, its log line written. Again while the foreign locker holds the session lock: it stays off
# every output until the unlock, then comes back (D55). The output is removed again on exit.
gather_out=GF-GATHER
on_any_output() { # the foot window's frame meets an output
  local x y w h _a
  read -r x y w h _a < <(geometry)
  say "  foot at $x,$y ${w}x$h; outputs: $(nestctl monitors -j | jq -c '[.[] | [.name, .x, .y, .width, .height]]')"
  [[ -n ${x:-} ]] && nestctl monitors -j | jq -e --argjson x "$x" --argjson y "$y" --argjson w "$w" --argjson h "$h" \
    'any(.[]; .x < $x + $w and .x + .width > $x and .y < $y + $h and .y + .height > $y)' >/dev/null
}
gathered_on_ref() { # the foot window centred across GF-REF's work area (core gatheredFrame), 1 px of rounding
  local x _y w _h _a ax _ay aw _ah
  read -r x _y w _h _a < <(geometry)
  read -r ax _ay aw _ah < <(area_of "$out")
  say "  foot at x $x width $w; $out work area x $ax width $aw (centred: $(( ax + (aw - w) / 2 )))"
  [[ -n ${x:-} && -n ${ax:-} ]] && (( x - (ax + (aw - w) / 2) <= 1 && (ax + (aw - w) / 2) - x <= 1 ))
}
gather_place() { # the foot window onto the headless output's area, its Desktop kept: true when it is there, off GF-REF
  local gx gy x _y _w _h _a
  read -r gx gy < <(nestctl monitors -j | jq -r --arg o "$gather_out" '.[] | select(.name == $o) | "\(.x) \(.y)"')
  [[ -n ${gx:-} ]] || return 1
  nestctl dispatch "hl.dsp.window.move({ x = $((gx + 100)), y = $((gy + 100)), window = 'address:$gaddr' })" >>"$log" 2>&1
  sleep 0.8
  read -r x _y _w _h _a < <(geometry)
  say "  foot placed at x ${x:-?} (output $gather_out at $gx,$gy)"
  [[ -n ${x:-} ]] && (( x >= gx )) && [[ $(nestctl clients -j | jq -r --arg a "$gaddr" '.[] | select(.address == $a) | .workspace.id') == "$gather_home" ]]
}
gather_count() { nestctl rollinglog 2>/dev/null | grep -ac "was off every output"; }
gather_logged() { # the plugin's gathering line since `gather_from` (log file line) or `gather_seen` (rolling log count): polled up
  # to 3 s, the log file is buffered (integrator re-review of 67800eb, B)
  local _ n
  for _ in $(seq 1 15); do
    tail -n +"$((gather_from + 1))" "$hyprlog" 2>/dev/null | grep -aq "was off every output" && return 0
    n=$(gather_count)
    (( ${n:-0} > ${gather_seen:-0} )) && return 0
    sleep 0.2
  done
  return 1
}
gather_not_logged() { ! gather_logged; }
if [[ -n $(geometry) ]] && nestctl output create headless "$gather_out" >>"$log" 2>&1; then
  sleep 1.5
  gaddr=$(geometry | awk '{print $5}')
  check "gather: the window out of zoom and full screen first" fs_clear "$gaddr"
  declare -F free_foot >/dev/null && free_foot
  gather_home=$(nestctl clients -j | jq -r --arg a "$gaddr" '.[] | select(.address == $a) | .workspace.id')
  check "gather: the window on the headless output's area, still on $out's Desktop ($gather_home)" gather_place
  gather_from=$(log_lines)
  gather_seen=$(gather_count)
  nestctl output remove "$gather_out" >>"$log" 2>&1
  sleep 1.5
  check "gather: Hyprland alive after the unplug" alive
  check "gather: the plugin logs the window it gathered (D67)" gather_logged
  check "gather: the window lies on an output after the unplug" on_any_output
  check "gather: centred across $out's work area at its size" gathered_on_ref
  # Behind the lock screen: nothing moves until the unlock (D55, D67).
  if nestctl output create headless "$gather_out" >>"$log" 2>&1; then
    sleep 1.5
    check "gather locked: the window on the headless output's area again" gather_place
    read -r lock_x _ < <(geometry)
    if lock_session; then
      gather_from=$(log_lines)
      gather_seen=$(gather_count)
      nestctl output remove "$gather_out" >>"$log" 2>&1
      sleep 1.5
      read -r locked_x _ < <(geometry)
      check "gather locked: the window stays where it was behind the lock screen (x ${locked_x:-?}, was $lock_x)" test "${locked_x:-}" = "$lock_x"
      check "gather locked: nothing gathered while locked" gather_not_logged
    else
      check "gather locked: the foreign locker holds the session lock (${locked:-no answer})" false
      nestctl output remove "$gather_out" >>"$log" 2>&1 || true
    fi
    check "gather locked: released, Hyprland reports the session unlocked" unlock_session
    sleep 1
    check "gather locked: at the unlock, the window lies on an output" on_any_output
    check "gather locked: at the unlock, centred across $out's work area" gathered_on_ref
  fi
  declare -F free_foot >/dev/null && free_foot
else
  nestctl output remove "$gather_out" >>"$log" 2>&1 || true
  say "SKIP: gather case (no foot window, or no headless output)"
fi

c1_cases

# Every SKIP of the run again at the end, so a case that did not run (the X11 menu without an X display, Chromium not
# installed...) is not lost in the log (integrator follow-up of PR #42).
mapfile -t skips < <(grep -o 'SKIP: .*' "$log")
if ((${#skips[@]})); then
  say "tiling: ${#skips[@]} skipped, NOT VERIFIED in this run:"
  for line in "${skips[@]}"; do say "  ${line#SKIP: }"; done
fi
check "Hyprland alive" alive
exit $fail
