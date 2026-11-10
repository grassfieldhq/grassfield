#!/usr/bin/env bash
# Captures of the shell surfaces that draw app icons (Dock and desktop together, Apps, Search with its selected row, the
# Settings icon-mode picker) in the four icon appearance modes and both appearances, for the look of the system plate
# (ADR-0014, docs/specs/ui.md "Icon shader"). NOT a regression scenario: writes
# .dev/visual/icon-modes-surfaces/ims-<surface>-<appearance>-<mode>.<lang>.png. Run it as a BARE command.
#
#   tests/visual/icon-modes-surfaces.sh [en|fr] ["dark light"] ["default dark clear tinted"]
source "$(dirname "$0")/lib.sh"
VS_LANG=${1:-$VS_LANG}
export VISUAL_LANG=$VS_LANG
APPEARANCES=${2:-"dark light"}
MODES=${3:-"default dark clear tinted"}
OUT=$VS_STATE/icon-modes-surfaces
mkdir -p "$OUT"

config() { # config APPEARANCE MODE
  mkdir -p "$VS_DEV/config"
  printf '{"version":1,"appearance":"%s","lock":{"idleMinutes":0},"icons":{"folderColor":"theme","mode":"%s"}}\n' "$1" "$2" > "$VS_DEV/config/grassfield.json.tmp"
  mv "$VS_DEV/config/grassfield.json.tmp" "$VS_DEV/config/grassfield.json"
  vs_sleep 1.5
}

shot() { vs_capture "$1" >/dev/null; cp "$VS_SHOTS/$1.$VS_LANG.png" "$OUT/$1.$VS_LANG.png"; echo "$OUT/$1.$VS_LANG.png"; }

vs_session
vs_reset
for appearance in $APPEARANCES; do
  for mode in $MODES; do
    config "$appearance" "$mode"
    vs_ipc controlcenter appearance "$appearance" >/dev/null
    shot "ims-desktop-$appearance-$mode"
    vs_ipc apps open >/dev/null
    vs_sleep 1
    shot "ims-apps-$appearance-$mode"
    vs_ipc apps close >/dev/null
    vs_sleep 0.5
    vs_ipc search open files >/dev/null
    vs_sleep 1.5
    shot "ims-search-$appearance-$mode"
    vs_ipc search close >/dev/null
    vs_sleep 0.5
  done
done

# The Dock over a white, a grey and a black wallpaper (R7-REQ-13, test_a2_dock): the Dock is an almost clear glass, so what the icons stand on is the wallpaper itself;
# Clear in the dark appearance must stay legible on white (dark smoked plate, light ink). Writes ims-dock-<wallpaper>-<appearance>-<mode>.
for wall in white grey black; do
  case $wall in white) c='#ffffff' ;; grey) c='#808080' ;; black) c='#000000' ;; esac
  magick -size 64x64 "xc:$c" "$OUT/wall-$wall.png"
done
for wall in white grey black; do
  vs_wallpaper "$OUT/wall-$wall.png" || echo "wallpaper $wall refused" >&2
  # The live Dock's icons follow the glass they sit on (R7-REQ-13): the wallpaper is known to the shell (source "wallpaper") and the tone follows it, in any appearance.
  # Polled, not read after a fixed sleep: taken once VS_OUTPUT reports the wallpaper with the expected tone, within ICON_SURFACE_BOUND_MS (5 s); the settle time (from
  # vs_wallpaper returning) is printed for each wallpaper and the run fails only past the bound. Only VS_OUTPUT is checked: the nested session's own output (WAYLAND-1)
  # is not rendered by the pinned run, so its wallpaper probe has no paint to read and its reading stays the previous one.
  case $wall in black) want_dark=true ;; *) want_dark=false ;; esac
  t0=$(date +%s%N); surf=; src=missing; dark=missing
  while :; do
    surf=$(vs_ipc dock iconsurface)
    src=$(printf '%s' "$surf" | jq -r --arg o "$VS_OUTPUT" '.[$o].source // "missing"' 2>/dev/null)
    dark=$(printf '%s' "$surf" | jq -r --arg o "$VS_OUTPUT" '.[$o].dark | tostring' 2>/dev/null)
    [ "$src" = wallpaper ] && [ "$dark" = "$want_dark" ] && break
    [ $((($(date +%s%N) - t0) / 1000000)) -lt ${ICON_SURFACE_BOUND_MS:-5000} ] || break
    sleep 0.1
  done
  settle=$((($(date +%s%N) - t0) / 1000000))
  echo "dock iconsurface over $wall: settled in ${settle} ms: $surf"
  { [ "$src" = wallpaper ] && [ "$dark" = "$want_dark" ]; } || { echo "FAIL: the live Dock over $wall: source $src, dark=$dark, expected wallpaper and dark=$want_dark after ${settle} ms" >&2; ICON_SURFACE_FAIL=1; }
  for appearance in $APPEARANCES; do
    for mode in $MODES; do
      config "$appearance" "$mode"
      vs_ipc controlcenter appearance "$appearance" >/dev/null
      shot "ims-dock-$wall-$appearance-$mode"
    done
  done
done
vs_wallpaper "" || true

vs_spawn "$VS_DEV/build/grassfield-settings"
vs_wait_clients 1
vs_sleep 2
for appearance in $APPEARANCES; do
  for mode in $MODES; do
    config "$appearance" "$mode"
    vs_ipc controlcenter appearance "$appearance" >/dev/null
    shot "ims-settings-$appearance-$mode"
  done
done
vs_kill_clients
echo "captures in $OUT"
[ -z "${ICON_SURFACE_FAIL:-}" ] || exit 1
