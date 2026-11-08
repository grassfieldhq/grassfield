#!/usr/bin/env bash
# The menu bar's pointer and keyboard behaviour against the macOS model (docs/specs/menubar.md), on GF-REF with one foot
# window focused (app name, File/Window titles). Each check prints PASS/FAIL; the captures are in $VS_SHOTS/mbm-*.png.
#   press-opens       a press on a title opens its menu before the release (macOS opens on mouse down)
#   press-drag-release  press on Window, drag onto its first row (Minimize), release: the item runs (foot minimized)
#   hover-switch      with the app menu open, moving onto Window (no click) opens the Window menu
#   status-switch     with the volume menu open, moving onto the network item opens the network menu
#   click-closes      a click on the open title closes its menu
#   keyboard-right    with the app menu open, Right moves to the next title's menu (no submenu on the current row)
#   keyboard-walk     keyboard only (no pointer): Right walks the titles and the status menus and wraps, Left wraps back
#   keyboard-status   `menubar open status` (Ctrl+F8) opens the first status menu
#   no-hover-idle    hovering a title with no menu open draws nothing (macOS has no hover highlight in the bar)
#   fullscreen-reveal with foot full screen the bar is hidden, and the pointer at the top edge reveals it over the window
#   fullscreen-hidden  the IPC state of that bar: hidden (away) on the overlay layer with the exclusive zone kept, shown at the edge, away again
# Usage (bare command): tests/visual/menubar-macos.sh
source "$(dirname "$0")/lib.sh"

fail=0
check() {
  local name=$1
  shift
  if "$@"; then echo "PASS: $name"; else echo "FAIL: $name"; fail=1; fi
}
kind() { vs_ipc menubar openKind | tr -d '"'; }
is_kind() { [[ $(kind) == "$1@$VS_OUTPUT" ]]; }
closed() { [[ -z $(kind) ]]; }
title_x() { # kind -> centre x of that left title on GF-REF
  vs_ipc menubar bridgeState "$VS_OUTPUT" | jq -r --arg k "$1" '.bar[] | select(.kind == $k) | (.x + .w / 2 | floor)' | head -n 1
}
foot_state() { "$VS_ROOT/scripts/nestctl" clients -j | jq -r '.[] | select(.title == "mbm-foot") | .workspace.name'; }
px_diff() { # a b crop -> differing pixels (fuzz 6 %)
  { magick compare -fuzz 6% -metric AE <(magick "$1" -crop "$3" +repage png:-) <(magick "$2" -crop "$3" +repage png:-) null: 2>&1 || true; } | awk '{print int($1)}'
}
reset_menus() { vs_ipc menubar close >/dev/null; vs_sleep 0.4; }

vs_session >/dev/null
vs_reset >/dev/null
vs_foot mbm-foot 80x20 >/dev/null
vs_wait_clients 1 >/dev/null || true
vs_sleep 1.5
app_x=$(title_x app)
win_x=$(title_x window)
echo "titles: app at x=$app_x, window at x=$win_x"

# press-opens (one pointer process for the press and its release: a release from another virtual pointer is not the
# same button)
reset_menus
vs_pointer abs "$app_x" 12 down sleep 1200 up >/dev/null &
press=$!
vs_sleep 0.6
k=$(kind)
wait "$press"
check "press-opens: the app menu is open while the button is still down (got '${k:-none}')" test "$k" = "app@$VS_OUTPUT"

# click-closes. The second click comes 1 px away: Hyprland gives a layer that maps under a resting pointer no pointer
# focus until the pointer moves, so a click with no motion at all since the menu opened reaches no surface (known
# limit, docs/specs/menubar.md; a real mouse moves, a trackpad tap may not).
reset_menus
vs_pointer abs "$app_x" 12 click >/dev/null
vs_sleep 0.5
opened=$(kind)
vs_pointer abs "$((app_x + 1))" 12 click >/dev/null
vs_sleep 0.5
check "click-closes: a click on the open title closes it (opened '${opened:-none}', now '$(kind)')" closed

# hover-switch
reset_menus
vs_pointer abs "$app_x" 12 click >/dev/null
vs_sleep 0.5
vs_pointer abs "$win_x" 12 >/dev/null
vs_sleep 0.6
k=$(kind)
VS_NOPARK=1 vs_capture mbm-hover-switch >/dev/null
check "hover-switch: moving onto Window with the app menu open opens Window (got '${k:-none}')" test "$k" = "appwindow@$VS_OUTPUT"

# keyboard-right
reset_menus
vs_pointer abs "$app_x" 12 click >/dev/null
vs_sleep 0.5
# The menu takes the keyboard a moment after it maps (an Exclusive layer; seconds in a loaded session, the audit ran this
# with an 8 h soak on the same GPU): press Right until the menu is open and has the keyboard, at most 8 times. Stepping is
# one title per key that arrived, so the check is "left the app title", not a fixed target.
key_until() { # key from-kind -> waits for the kind to change; echoes the new kind
  local key=$1 from=$2 n
  for n in 1 2 3 4 5 6 7 8; do
    "$VS_ROOT/scripts/dev/keys.sh" -k "$key" >/dev/null
    vs_sleep 0.6
    [[ $(kind) != "$from@$VS_OUTPUT" ]] && break
  done
  kind
}
k=$(key_until Right app)
check "keyboard-right: Right in the app menu moves to the next title (got '${k:-none}', overlay keyboard wait '$(vs_ipc menubar keyboardWait | tr -d '"')')" test "$k" != "app@$VS_OUTPUT" -a -n "$k"

# keyboard-walk: with no pointer at all (as Ctrl+F2 opens it), Right visits every title and every status menu in bar
# order and wraps; Left goes back. The status items are the ones the audit found unreachable (A11Y-02).
reset_menus
vs_ipc menubar open system "$VS_OUTPUT" >/dev/null
vs_sleep 0.8
seen=""
cur=system
for _ in $(seq 1 14); do
  nk=$(key_until Right "$cur")
  [[ -n $nk ]] || break
  cur=${nk%@*}
  seen+=" $cur"
  [[ $cur == system ]] && break
done
check "keyboard-walk: Right from the Grassfield menu reaches the Window menu and the status menus and wraps back ($seen)" \
  bash -c '[[ " $1 " == *" app "* && " $1 " == *" appwindow "* && " $1 " == *" network "* && " $1 " == *" volume "* && " $1 " == *" controlcenter "* && "$1" == *system ]]' _ "$seen"
k=$(key_until Left system)
check "keyboard-walk: Left from the Grassfield menu wraps to the last status menu (got '${k:-none}')" test "$k" = "controlcenter@$VS_OUTPUT"
# keyboard-focus-walk (R7-FUN-08 / GF-002): the real binding (Ctrl+F2) with the foot window focused, then the whole walk by
# key, each step asserting WHICH surface has the keyboard (the popup's Overlay window, never the foot window): Right across
# the titles and the status menus, Left back, Down in the open menu, Escape back to the window that had the keys.
holder() { vs_ipc menubar keyboardHolder | tr -d '"'; }
wait_holder() { # want -> waits up to ~6 s for the keyboard holder to be `want`
  local n
  for n in $(seq 1 12); do
    [[ $(holder) == "$1" ]] && return 0
    vs_sleep 0.5
  done
  return 1
}
active_title() { "$VS_ROOT/scripts/nestctl" activewindow -j | jq -r '.title // ""'; }
# Presses `key` until the open kind leaves `from` (the menu takes the keys a moment after it maps), echoes the new kind. A key
# that arrives while the overlay does NOT hold the keyboard went to the window below: the step fails on that, not on a retry.
step_key() { # key from-kind
  local key=$1 from=$2 n
  for n in 1 2 3 4 5 6 7 8; do
    [[ $(holder) == overlay ]] || { echo "lost@$(holder)"; return; }
    "$VS_ROOT/scripts/dev/keys.sh" -k "$key" >/dev/null
    vs_sleep 0.6
    [[ $(kind) != "$from@$VS_OUTPUT" ]] && break
  done
  kind
}
reset_menus
vs_sleep 1.0
fw_before=$(active_title)
# A compositor bind: wtype's modifiers reach apps but never the compositor's binds, so the chord goes through
# tests/tools/vkbd, as tests/visual/flow-lib.sh fl_chord does.
timeout 20 "$VS_ROOT/tests/tools/vkbd/vkbd.sh" down Control_L sleep 60 tap F2 sleep 60 up Control_L >/dev/null
for _ in $(seq 1 10); do [[ $(kind) == "system@$VS_OUTPUT" ]] && break; vs_sleep 0.4; done
check "focus-walk: Ctrl+F2 with the foot window focused opens the Grassfield menu (got '$(kind)', window '$fw_before')" is_kind system
check "focus-walk: after Ctrl+F2 the menu bar's popup holds the keyboard, not the window (holder '$(holder)')" wait_holder overlay
seen=""
cur=system
lost=""
for _ in $(seq 1 14); do
  nk=$(step_key Right "$cur")
  if [[ $nk == lost@* ]]; then lost="Right after '$seen': ${nk#lost@}"; break; fi
  [[ -n $nk ]] || { lost="Right after '$seen': popup closed"; break; }
  cur=${nk%@*}
  seen+=" $cur"
  [[ $(holder) == overlay ]] || { lost="after Right to '$cur': holder '$(holder)'"; break; }
  [[ $cur == system ]] && break
done
check "focus-walk: Right x$(wc -w <<<"$seen") visits app menus and the status area and wraps, the popup keeps the keyboard at every step ($seen${lost:+; LOST $lost})" \
  bash -c '[[ -z $2 && " $1 " == *" app "* && " $1 " == *" network "* && " $1 " == *" controlcenter "* && "$1" == *system ]]' _ "$seen" "$lost"
back=""
cur=system
lost=""
for _ in $(seq 1 14); do
  nk=$(step_key Left "$cur")
  if [[ $nk == lost@* ]]; then lost="Left after '$back': ${nk#lost@}"; break; fi
  [[ -n $nk ]] || { lost="Left after '$back': popup closed"; break; }
  cur=${nk%@*}
  back+=" $cur"
  [[ $cur == app ]] && break
done
check "focus-walk: Left walks back to the app menu with the popup holding the keyboard ($back${lost:+; LOST $lost})" \
  bash -c '[[ -z $2 && "$1" == *app ]]' _ "$back" "$lost"
before=$(kind)
"$VS_ROOT/scripts/dev/keys.sh" -k Down >/dev/null
vs_sleep 0.6
check "focus-walk: Down in the open menu keeps it open and keeps the keyboard (kind '$(kind)', holder '$(holder)')" \
  bash -c '[[ $1 == "$2" && $3 == overlay ]]' _ "$(kind)" "$before" "$(holder)"
"$VS_ROOT/scripts/dev/keys.sh" -k Escape >/dev/null
for _ in $(seq 1 10); do closed && break; vs_sleep 0.4; done
check "focus-walk: Escape closes the menu (got '$(kind)')" closed
for _ in $(seq 1 10); do [[ $(active_title) == "$fw_before" ]] && break; vs_sleep 0.5; done
check "focus-walk: Escape returns the keyboard to the window that had it ('$fw_before', now '$(active_title)')" test "$(active_title)" = "$fw_before"
# Ctrl+F8 equivalent: the status menus start at the first status item.
reset_menus
vs_ipc menubar open status "$VS_OUTPUT" >/dev/null
vs_sleep 0.6
k=$(kind)
check "keyboard-status: 'open status' opens the first status menu (got '${k:-none}')" bash -c '[[ $1 =~ ^(network|volume|battery|controlcenter|nowplaying|tray)@ ]]' _ "$k"

# status-switch: the network and volume items sit left of Quick Settings and the clock; open volume through IPC, then move
# onto the network item, found from the bar's right side in the capture-free way: IPC opens give the anchor, so use
# the popup's own x (volume opens aligned to its item's right edge) and step one item left.
# (GF-058: the pointer rests on the app title after the checks above, and a resting pointer over a title switches an open
# menu to that title's: the capture showed the app menu. Park it first, and assert the volume menu is the one that is open
# before capturing.)
reset_menus
vs_park
vs_ipc menubar open volume "$VS_OUTPUT" >/dev/null
for _ in 1 2 3 4 5 6 7 8 9 10; do is_kind volume && break; vs_sleep 0.3; done
check "status-switch: the volume menu is open before its capture (got '$(kind)')" is_kind volume
read -r W _ < <(magick identify -format '%w %h\n' "$(VS_NOPARK=1 vs_capture mbm-volume-open)")
check "status-switch: the volume menu is still the open one after its capture (got '$(kind)')" is_kind volume
# Right side: clock (~140 px), Quick Settings, volume, network from the right edge; probe leftwards until the kind changes.
k=""
for x in $(seq $((W - 200)) -12 $((W - 330))); do
  vs_pointer abs "$x" 12 >/dev/null
  vs_sleep 0.3
  k=$(kind)
  [[ $k == "network@$VS_OUTPUT" ]] && break
done
check "status-switch: moving onto the network item with the volume menu open opens it (got '${k:-none}')" test "$k" = "network@$VS_OUTPUT"

# press-drag-release on Window > Minimize (first row)
reset_menus
restore_ws=$(foot_state)
vs_pointer abs "$win_x" 12 down sleep 400 drag "$((win_x + 30))" 30 sleep 150 drag "$((win_x + 40))" 44 sleep 300 up >/dev/null
vs_sleep 1.2
ws=$(foot_state)
check "press-drag-release: Window > Minimize chosen by press, drag and release (foot on '${ws:-?}')" test "$ws" = "special:minimized"
# Bring foot back for the next checks (Dock click equivalent: the platform restores it on focus).
if [[ $ws == special:minimized ]]; then
  # (A plain focus does not bring it back: move it to the workspace it came from, the one shown on GF-REF.)
  back=$("$VS_ROOT/scripts/nestctl" clients -j | jq -r '.[] | select(.title == "mbm-foot") | .address' | head -n 1)
  "$VS_ROOT/scripts/nestctl" dispatch "hl.dsp.window.move({ workspace = \"$restore_ws\", follow = false, window = \"address:$back\" })" >/dev/null 2>&1 || true
  vs_sleep 0.8
  "$VS_ROOT/scripts/nestctl" dispatch "hl.dsp.focus({ window = 'address:$back' })" >/dev/null 2>&1 || true
  vs_sleep 1
fi

# no-hover-idle: crop around the app title with the pointer parked vs hovering it
reset_menus
idle=$(vs_capture mbm-idle)
vs_pointer abs "$app_x" 12 >/dev/null
vs_sleep 0.6
hover=$(VS_NOPARK=1 vs_capture mbm-hover)
d=$(px_diff "$idle" "$hover" "160x24+$((app_x - 80))+0")
check "no-hover-idle: hovering a title with no menu open draws nothing ($d px changed)" test "$d" -lt 40

# fullscreen-reveal
reset_menus
addr=$("$VS_ROOT/scripts/nestctl" clients -j | jq -r '.[] | select(.title == "mbm-foot") | .address' | head -n 1)
"$VS_ROOT/scripts/nestctl" dispatch "hl.dsp.window.fullscreen({ mode = 'fullscreen', window = 'address:$addr' })" >/dev/null 2>&1
vs_sleep 1.5
vs_pointer abs 960 540 >/dev/null
vs_sleep 0.8
fs_away=$(VS_NOPARK=1 vs_capture mbm-fullscreen-away)
st_away=$(vs_ipc menubar autohide "$VS_OUTPUT")
vs_pointer abs 960 0 >/dev/null
vs_sleep 1.2
fs_edge=$(VS_NOPARK=1 vs_capture mbm-fullscreen-edge)
st_edge=$(vs_ipc menubar autohide "$VS_OUTPUT")
vs_pointer abs 960 540 >/dev/null
vs_sleep 1.5
st_gone=$(vs_ipc menubar autohide "$VS_OUTPUT")
read -r FW _ < <(magick identify -format '%w %h\n' "$fs_edge")
d=$(px_diff "$fs_away" "$fs_edge" "${FW}x22+0+1")
check "fullscreen-reveal: the bar appears when the pointer reaches the top edge over a full-screen window ($d px changed)" test "$d" -gt 400
check "fullscreen-hidden: full screen hides the bar on the overlay layer with the exclusive zone kept, the edge shows it, leaving the bar hides it again ($st_away / $st_edge / $st_gone)" \
  bash -c '[[ $(jq -r "[.fullscreen, .away, .overlay, .zone] | @csv" <<<"$1") == "true,true,true,24" && $(jq -r ".state" <<<"$2") == shown && $(jq -r ".away" <<<"$3") == true ]]' _ "$st_away" "$st_edge" "$st_gone"
"$VS_ROOT/scripts/nestctl" dispatch "hl.dsp.window.fullscreen({ mode = 'fullscreen', window = 'address:$addr' })" >/dev/null 2>&1 || true

reset_menus
check "no QML error in the shell log" test "$(grep -cE 'TypeError|ReferenceError|Binding loop' "$VS_DEV/shell.log")" = 0
exit $fail
