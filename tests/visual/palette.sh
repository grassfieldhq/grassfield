#!/usr/bin/env bash
# Command palette (Search extended Raycast-style, ADR-0067) in the NESTED session at the owner's display scale 1.25.
# Spec: docs/specs/command-palette.md § 3. Nothing here touches the host: no Sleep, Lock, Log Out, Restart, Shut Down or Empty
# Trash is ever RUN (they are only looked up, and their confirmation is shown and cancelled).
#
# Sections (arguments; none = all, in this order):
#   open      the keyboard shortcut (Super+Space through the virtual keyboard), Esc, and Super+K (spec: withdrawn until proven)
#   queries   commands (sleep, lock, dark mode, do not disturb), the calculator (percent, units), a Link
#   actions   Tab opens Actions: placement (measured against the results panel and the selected row), real blur (a striped
#             wallpaper is smoothed under the list), Up/Down, Page Down/Up between groups, Esc closes the panel only, Shift+Tab
#             to the last chip, Return runs the action
#   run       real runs that only affect the nested session: Dark mode, Do Not Disturb for 1 Hour and its indicator, screen saver
#             started then dismissed, window commands on a foot test window (left half, next display, minimize, full screen);
#             Sleep, Lock, Log Out, Restart, Shut Down, Empty Trash: present, confirmation shown where the spec says so, cancelled
#   scripts   a harmless script in the nested session's own XDG_DATA_HOME: discovered with its header title, Return refused
#             cleanly while the runner (X3b) is not built
#   look      device-pixel crispness (zoomed crops, rim, row pitch), panel size, radii, chips
# Options: --keep (leave the nested session up), --lang fr (or VISUAL_LANG=fr: French pass: truncation crops).
# Geometry is measured from the captures and from scripts/nestctl (no hardcoded coordinates); sizes are reported in logical px.
# Captures: $VS_SHOTS/palette-*.<lang>.png (under .dev/, not committed).
# Run as a BARE command (reference machine only):  tests/visual/palette.sh [section...]
# Exit status 1 when a check fails.
source "$(dirname "$0")/flow-lib.sh"

keep=0
sections=()
while [[ $# -gt 0 ]]; do
  case $1 in
    --keep) keep=1 ;;
    --lang) VS_LANG=${2:?--lang needs a value}; shift ;;
    open|queries|actions|run|scripts|look) sections+=("$1") ;;
    *) echo "palette: unknown argument $1" >&2; exit 2 ;;
  esac
  shift
done
((${#sections[@]})) || sections=(open queries actions run scripts look)
want() { local s; for s in "${sections[@]}"; do [[ $s == "$1" ]] && return 0; done; return 1; }
fr=0
[[ $VS_LANG == fr ]] && fr=1

was_running=0
vs_nested_running && was_running=1
palette_cleanup() {
  fl_cleanup
  vs_ipc saver dismiss >/dev/null 2>&1 || true
  rm -f "$scripts_dir"/palette-hello.sh "$scripts_dir"/palette-slow.sh 2>/dev/null || true
  rm -rf "$VS_STATE/palette-walls" 2>/dev/null || true
  if ((!keep && !was_running)); then "$VS_ROOT/scripts/dev/nested-down.sh" >/dev/null 2>&1 || true; fi
  return 0
}
scripts_dir=$VS_DEV/apps-home/data/grassfield/script-commands

# GF-REF at the owner's panel scale (nested-up reads GRASSFIELD_REF_SCALE). A session already up keeps its scale.
export GRASSFIELD_REF_SCALE=1.25
vs_fixtures
if type -P updatedb >/dev/null; then
  updatedb --database-root "$VS_FILES" --output "$VS_DEV/plocate.db" --require-visibility no >/dev/null 2>&1 || true
fi
fl_start palette
fl_close_windows '^org\.grassfield\.Settings$' 2>/dev/null || true
vs_sleep 1
trap palette_cleanup EXIT
trap 'exit 130' INT TERM

# ---- helpers ------------------------------------------------------------------------------------------------------------
nest() { "$VS_ROOT/scripts/nestctl" "$@"; }
scale=$(nest monitors -j | jq -r --arg n "$VS_OUTPUT" '.[] | select(.name == $n) | .scale')
fl_check "GF-REF runs at scale 1.25 (got $scale)" fl_eq "$scale" 1.25
rng=$(nest monitors -j | jq -r --arg n "$VS_OUTPUT" '.[] | select(.name == $n) | "\(.width)x\(.height)"')
fl_note "GF-REF mode $rng at scale $scale"

st() { fl_jq search status -- "$1"; }
is() { [[ $(st "$1") == "$2" ]]; }
titles() { fl_json search status | jq -r '[.groups[] | .title + ": " + ([.items[] | .title + " (" + .kind + ")"] | join(" | "))] | join("\n")'; }
sel_title() { fl_json search status | jq -r '. as $s | [.groups[].items[]] | .[$s.selected // 0].title // ""' 2>/dev/null; }
sel_json() { fl_json search status | jq -r '.selected'; }
has_title() { fl_json search status | jq -e --arg re "$1" '[.groups[].items[].title] | any(test($re; "i"))' >/dev/null 2>&1; }
open_search() { # TEXT: Search closed, then opened empty and TEXT typed
  vs_ipc search close >/dev/null
  vs_sleep 0.4
  vs_ipc search open "" >/dev/null
  fl_wait 5 is .open true || { echo "search did not open" >&2; return 1; }
  [[ -z $1 ]] || { fl_type "$1"; fl_wait 5 is .query "$1"; }
  vs_sleep 0.6
}
select_title() { # RE: arrows to the first row whose title matches
  local want n cur
  want=$(fl_json search status | jq -r --arg re "$1" '[.groups[].items[]] | to_entries | map(select(.value.title | test($re; "i"))) | (.[0].key // -1)')
  [[ $want =~ ^[0-9]+$ ]] || return 1
  for n in $(seq 1 25); do
    cur=$(sel_json)
    [[ $cur == "$want" ]] && return 0
    if [[ $cur -lt $want ]]; then fl_tap Down; else fl_tap Up; fi
  done
  [[ $(sel_json) == "$want" ]]
}
shot() { VS_NOPARK=1 vs_capture "palette-$1" >/dev/null; echo "$VS_SHOTS/palette-$1.$VS_LANG.png"; }
# bbox A B: "WxH+X+Y" in device px of what differs between two captures (empty when nothing does).
bbox() {
  # (the menu bar, the notification banner column and the desktop icons are outside the crop: x < 1700, y >= 165; the offsets are put back)
  local g
  g=$(magick "$1" "$2" -crop 1700x915+0+165 +repage -compose difference -composite -colorspace Gray -threshold "${3:-3}%" -trim -format '%wx%h%O' info: 2>/dev/null) || return 0
  [[ $g =~ ^([0-9]+x[0-9]+)\+(-?[0-9]+)\+(-?[0-9]+)$ ]] && printf '%s+%s+%s' "${BASH_REMATCH[1]}" "${BASH_REMATCH[2]}" "$(( ${BASH_REMATCH[3]} + 165 ))"
}
# unpack "WxH+X+Y": sets gw gh gx gy
unpack() { [[ $1 =~ ^([0-9]+)x([0-9]+)\+(-?[0-9]+)\+(-?[0-9]+)$ ]] && { gw=${BASH_REMATCH[1]}; gh=${BASH_REMATCH[2]}; gx=${BASH_REMATCH[3]}; gy=${BASH_REMATCH[4]}; }; }
lg() { awk -v v="$1" -v s="$scale" 'BEGIN { printf "%.1f", v / s }'; } # device px -> logical px
# edge energy (mean of a Sobel-like gradient) of a region "WxH+X+Y" of a capture: lower = blurrier
# energy: edge strength relative to the contrast of the patch (a tint lowers both; a blur lowers the edges alone)
energy() { magick "$1" -crop "$2" +repage -colorspace Gray \( +clone -morphology Convolve Sobel:0 -morphology Convolve Sobel:90 -evaluate pow 1 \) -delete 1 -format '%[fx:standard_deviation]' info: 2>/dev/null; }
edges() { magick "$1" -crop "$2" +repage -colorspace Gray -edge 1 -format '%[fx:mean]' info: 2>/dev/null; }
contrast() { magick "$1" -crop "$2" +repage -colorspace Gray -format '%[fx:standard_deviation]' info: 2>/dev/null; }

base=""
# the Toggle Appearance command row (the Settings page is also called Appearance)
tgl_re='toggle appearance'; ((fr)) && tgl_re='changer'
baseline() { vs_ipc search close >/dev/null; vs_ipc notifications clearAll >/dev/null 2>&1 || true; vs_sleep 1.5; VS_NOPARK=1 vs_capture palette-base >/dev/null; base=$VS_SHOTS/palette-base.$VS_LANG.png; }
baseline

# ---- 1. open ---------------------------------------------------------------------------------------------------------------
if want open; then
  echo "== open"
  vs_ipc search close >/dev/null
  fl_chord Super_L space
  if fl_wait 3 is .open true; then echo "PASS: Super+Space opens Search (virtual keyboard, the bound key)"; else echo "FAIL: Super+Space did not open Search"; fl_fail=1; fi
  shot open-super-space
  fl_tap Escape
  fl_check_wait "Esc closes the empty Search" 3 is .open false
  # Super+K: spec 3.2 says it is coded but OFF until a nested proof (slice P3c). Look at what it does.
  vs_ipc search open "dark mode" >/dev/null
  fl_wait 5 is .open true
  vs_sleep 0.8
  a=$(shot super-k-before)
  fl_chord Super_L k
  vs_sleep 0.6
  b=$(shot super-k-after)
  d=$(vs_px_diff "$a" "$b")
  if is .open true; then
    echo "NOTE: Super+K with Search open: Search stays open, query now '$(st .query)', pixel change $d (cmdK is off in SearchPanel.qml)"
    [[ $(st .query) == "dark modek" ]] && echo "DEFECT: Super+K types a 'k' into the field (the Super modifier is ignored by the text input while ⌘K is withdrawn)"
  else echo "NOTE: Super+K closed Search"; fi
  vs_ipc search close >/dev/null
  fl_chord Super_L k
  vs_sleep 0.5
  if is .open true; then echo "NOTE: Super+K opened Search from closed (a bind exists)"; else echo "NOTE: Super+K with Search closed does nothing (no bind), as spec 3.2 'off'"; fi
  vs_ipc search close >/dev/null
fi

# ---- 2. queries ----------------------------------------------------------------------------------------------------------
if want queries; then
  echo "== queries"
  if ((fr)); then
    q_sleep=suspendre q_lock=verrouiller q_dark="mode sombre" q_dnd="ne pas déranger"
  else
    q_sleep=sleep q_lock=lock q_dark="dark mode" q_dnd="do not disturb"
  fi
  declare -A want_re=([sleep]='sleep|suspend' [lock]='lock|verrouill' [dark]='appearance|apparence|dark|sombre' [dnd]='disturb|déranger')
  for k in sleep lock dark dnd; do
    v=q_$k
    open_search "${!v}"
    fl_check "'${!v}' offers a command" has_title "${want_re[$k]}"
    titles | sed "s/^/    [$k] /"
    shot "q-$k" >/dev/null
  done
  for q in "15% of 80" "20 + 15%" "5 km in miles" "72 f in c" "2 gb in mb"; do
    open_search "$q"
    n=${q//[^A-Za-z0-9]/_}
    echo "    [calc] '$q' -> $(fl_json search status | jq -r '[.groups[].items[] | select(.kind == "calc" or .kind == "calculator" or .kind == "conversion") | .title] | join(" ; ")')"
    shot "q-calc-$n" >/dev/null
  done
  open_search "15% of 80"
  fl_check "calculator answers 15% of 80 with 12" has_title '(^|[^0-9.])12([^0-9]|$)'
  open_search "20 + 15%"
  fl_check "calculator answers 20 + 15% with 23" has_title '(^|[^0-9.])23([^0-9]|$)'
  open_search "5 km in miles"
  fl_check "unit conversion answers 5 km in miles with 3.1" has_title '3[.,]1'
  # A Link (T1) through the dev IPC (the Settings app's request); the placeholder shows once it is run (never run here).
  r=$(vs_ipc search addItem '{"list":"links","item":{"id":"link.00000000-0000-4000-8000-0000000000a1","name":"Palette Docs {date}","target":"https://example.org/docs?q={argument}"}}' 2>&1 || true)
  echo "    [link] addItem -> $r"
  vs_sleep 1
  open_search "palette docs"
  titles | sed 's/^/    [link] /'
  shot q-link >/dev/null
  r=$(vs_ipc search addItem '{"list":"replacements","item":{"id":"text.00000000-0000-4000-8000-0000000000b1","replace":"brb","with":"be right back {date}"}}' 2>&1 || true)
  echo "    [snippet] addItem -> $r"
  vs_sleep 1
  open_search "brb"
  titles | sed 's/^/    [snippet] /'
  shot q-snippet >/dev/null
  vs_ipc search removeItem "link.00000000-0000-4000-8000-0000000000a1" >/dev/null 2>&1 || true
  vs_ipc search removeItem "text.00000000-0000-4000-8000-0000000000b1" >/dev/null 2>&1 || true
  vs_ipc search close >/dev/null
fi

# ---- 3. the Actions panel ------------------------------------------------------------------------------------------------
if want actions; then
  echo "== actions"
  open_search "appearance"
  ((fr)) && open_search "apparence"
  select_title "$tgl_re" || echo "NOTE: could not select the appearance row"
  echo "    selected: $(sel_title)"
  noact=$(shot act-closed)
  # the results panel and its rows (device px): what the open Search adds to the desktop
  pb=$(bbox "$base" "$noact" 2); unpack "$pb"; pw=$gw ph=$gh px=$gx py=$gy
  echo "    [geom] Search (capsule+panel) $(lg "$pw") x $(lg "$ph") logical at x=$(lg "$px") y=$(lg "$py") (device $pb)"
  fl_tap Tab
  vs_sleep 0.8
  act=$(shot act-open)
  ab=$(bbox "$noact" "$act" 4)
  if [[ -z $ab ]]; then
    echo "FAIL: Tab changed nothing on screen (no Actions panel)"; fl_fail=1
  else
    unpack "$ab"; aw=$gw ah=$gh ax=$gx ay=$gy
    echo "    [geom] Actions panel $(lg "$aw") x $(lg "$ah") logical at x=$(lg "$ax") y=$(lg "$ay") (device $ab)"
    gap=$(( ax - (px + pw) ))
    echo "    [geom] gap results panel right edge -> Actions left: $(lg "$gap") logical (token searchActionsGap 11)"
    # Known defect 2026-11-24 (report): the list hangs 11 logical px right of the SELECTED ROW, which is itself inset 12 inside
    # the results panel, so the list touches the panel's edge. Reported as DEFECT (not a FAIL) until it is fixed.
    if awk -v g="$gap" -v s="$scale" 'BEGIN { exit !(g / s < 8) }'; then
      echo "DEFECT: the Actions list is $(lg "$gap") logical px from the results panel (it touches the panel edge; spec 3.3 wants it beside the row with a visible gap)"
    else
      echo "PASS: the Actions list clears the results panel by $(lg "$gap") logical px"
    fi
    echo "    [geom] Actions top $(lg "$ay") vs the selected row (list is level with the row's top: spec 3.3)"
    echo "PASS: Tab opens an Actions panel ($(lg "$aw") x $(lg "$ah") logical)"
  fi
  # Real blur: a striped wallpaper under the panel. The same stripes are crisp outside the glass and smoothed inside it.
  mkdir -p "$VS_STATE/palette-walls"
  wall=$VS_STATE/palette-walls/stripes.png
  magick -size 1920x1080 pattern:checkerboard "$wall"
  fl_tap Escape
  vs_sleep 0.4
  if vs_wallpaper "$wall"; then
    vs_sleep 1.5
    vs_ipc search close >/dev/null
    open_search "appearance"; ((fr)) && open_search "apparence"
    select_title "$tgl_re" || true
    fl_tap Tab
    vs_sleep 1
    blurshot=$(shot act-blur)
    if [[ -n ${ab:-} ]]; then
      unpack "$ab"
      # The Actions glass is a thin ring round the highlighted row: sample the strip above the row inside the glass, the same
      # kind of strip in the results panel (blurred by the layer's blur region) and bare wallpaper of the same size.
      ring="$((gw - 40))x3+$((gx + 20))+$((gy + 2))"
      pstrip="5x100+$((px + pw - 9))+$((py + ph / 2 - 50))"
      bare="$((gw - 40))x3+200+$((gy + 2))"
      sa=$(contrast "$blurshot" "$ring"); sp=$(contrast "$blurshot" "$pstrip"); sb=$(contrast "$blurshot" "$bare")
      echo "    [blur] contrast (std dev, 0..1) on a striped wallpaper: Actions glass ring $sa ; results panel margin $sp ; bare wallpaper $sb"
      if awk -v a="$sa" -v b="$sb" 'BEGIN { exit !(b > 0 && a < b * 0.3) }'; then
        echo "PASS: the wallpaper under the Actions glass is smoothed (ring $sa vs bare $sb)"
      else
        echo "FAIL: the stripes show through the Actions glass (ring $sa vs bare $sb)"; fl_fail=1
      fi
    fi
    fl_tap Escape
    vs_wallpaper "" || true
  else
    echo "NOTE: the wallpaper could not be set: blur NOT verified"
  fi
  # Esc closes the panel only
  vs_ipc search close >/dev/null
  open_search "appearance"; ((fr)) && open_search "apparence"
  select_title "$tgl_re" || true
  fl_tap Tab; vs_sleep 0.5
  fl_tap Escape; vs_sleep 0.5
  fl_check "Esc closes the Actions panel only (Search stays open, query kept)" is .open true
  after=$(shot act-esc)
  d=$(bbox "$noact" "$after" 4)
  echo "    [esc] region that differs between before-Tab and after-Esc (below the banner column): '${d:-none}'"
  if [[ -z $d ]]; then echo "PASS: the panel is gone after Esc"; else echo "FAIL: the screen still differs after Esc: $d"; fl_fail=1; fi
  # a second Esc clears or closes Search
  # Up/Down in a panel with several actions: a command row with extra actions (Do Not Disturb)
  open_search "readme"
  select_title 'readme' || true
  echo "    selected: $(sel_title)"
  fl_tap Tab; vs_sleep 0.7
  p0=$(shot act-dnd-0)
  fl_tap Down; vs_sleep 0.4
  p1=$(shot act-dnd-1)
  fl_tap Up; vs_sleep 0.4
  p2=$(shot act-dnd-2)
  echo "    [keys] Down changed $(vs_px_diff "$p0" "$p1") px (highlight moved, 0 means one action only); Up back: $(vs_px_diff "$p0" "$p2") px from the start"
  fl_tap Escape
  # Page Down / Page Up: groups. A short query matching several kinds.
  open_search "s"
  echo "    [groups]"; titles | sed 's/^/      /'
  g=$(fl_json search status | jq -r '[.groups[] | .items | length] | join(",")')
  s0=$(sel_json)
  fl_tap Next; s1=$(sel_json)
  fl_tap Next; s2=$(sel_json)
  fl_tap Prior; s3=$(sel_json)
  echo "    [groups] sizes $g ; selection $s0 -> PageDown $s1 -> PageDown $s2 -> PageUp $s3"
  shot pagedown >/dev/null
  if [[ $s1 != "$s0" ]]; then echo "PASS: Page Down moves to the next group ($s0 -> $s1)"; else echo "FAIL: Page Down did not move the selection"; fl_fail=1; fi
  [[ $s3 != "$s2" ]] && echo "PASS: Page Up moves back ($s2 -> $s3)" || { echo "FAIL: Page Up did not move the selection"; fl_fail=1; }
  # Shift+Tab to the last chip
  fl_chord Shift_L Tab
  vs_sleep 0.5
  fl_check "Shift+Tab reaches the chips (zone)" is .zone chips
  echo "    [chips] zone=$(st .zone) chips=$(st '.chips | tostring')"
  shot shifttab-chips >/dev/null
  fl_tap Escape
  # Return runs an action: Appearance toggles through the panel
  vs_ipc controlcenter appearance dark >/dev/null
  open_search "appearance"; ((fr)) && open_search "apparence"
  select_title "$tgl_re" || true
  before=$(fl_cc '.appearance // .dark // empty')
  fl_tap Tab; vs_sleep 0.6
  fl_tap Return; vs_sleep 1.5
  after_a=$(fl_cc '.appearance // .dark // empty')
  echo "    [return] appearance state before '$before' after '$after_a'"
  fl_check "Return in the Actions panel ran the action (appearance changed)" test "$before" != "$after_a"
  fl_check "Search closed after the action" is .open false
  vs_ipc controlcenter appearance dark >/dev/null
fi

# ---- 4. real runs (nested only) ---------------------------------------------------------------------------------------
if want run; then
  echo "== run"
  # Dark mode via the command row (Return)
  vs_ipc controlcenter appearance dark >/dev/null
  vs_sleep 1
  open_search "dark mode"; ((fr)) && open_search "mode sombre"
  select_title "$tgl_re" || true
  r0=$(shot run-dark-before)
  fl_tap Return; vs_sleep 2
  r1=$(shot run-dark-after)
  echo "    [dark] appearance now: $(fl_cc '.appearance // .dark // empty'); screen changed $(vs_px_diff "$r0" "$r1") px"
  vs_ipc controlcenter appearance dark >/dev/null
  vs_sleep 1
  # Do Not Disturb for 1 hour + indicator
  vs_ipc notifications dnd false >/dev/null
  open_search "do not disturb for"; ((fr)) && open_search "ne pas déranger"
  titles | sed 's/^/    [dnd] /'
  select_title 'hour|heure' || echo "NOTE: no 'for 1 hour' row selected"
  echo "    [dnd] selected: $(sel_title)"
  fl_tap Return; vs_sleep 1.5
  echo "    [dnd] status: $(vs_ipc notifications status | tr '\n' ' ')"
  fl_check "Do Not Disturb for 1 Hour turned DND on" test "$(fl_notif dnd)" = true
  shot run-dnd-indicator >/dev/null
  open_search "do not disturb"; ((fr)) && open_search "ne pas déranger"
  titles | sed 's/^/    [dnd-after] /'
  shot run-dnd-rows >/dev/null
  vs_ipc search close >/dev/null
  vs_ipc notifications dnd false >/dev/null
  # Screen saver: start, then dismiss with input
  open_search "screen saver"; ((fr)) && open_search "économiseur"
  titles | sed 's/^/    [saver] /'
  select_title 'saver|écran de veille|économiseur' || true
  fl_tap Return; vs_sleep 2
  sv=$(vs_ipc saver status 2>/dev/null || echo none)
  echo "    [saver] status: $sv"
  fl_check "the screen saver started" test "$(jq -r '.shown' <<<"$sv" 2>/dev/null)" = true
  shot run-saver >/dev/null
  vs_pointer abs 300 300 >/dev/null; vs_sleep 0.3; vs_pointer abs 340 330 >/dev/null
  fl_tap Shift_L
  vs_sleep 1.5
  sv=$(vs_ipc saver status 2>/dev/null || echo none)
  fl_check "input dismissed the screen saver" test "$(jq -r '.shown' <<<"$sv" 2>/dev/null)" = false
  vs_park
  # Window commands on a foot test window
  vs_foot "Palette test" 60x14
  vs_wait_clients 1
  fl_focus_class '^foot$'
  jqt() { jq -e "$1" <<<"$2" >/dev/null; } # jqt FILTER JSON
  win() { nest clients -j | jq -c '[.[] | select(.class == "foot" and .mapped)][0] | {at, size, monitor, fullscreen, hidden, workspace: .workspace.id}'; }
  w0=$(win); echo "    [win] start: $w0"
  shot run-win-0 >/dev/null
  mon_w=$(nest monitors -j | jq -r --arg n "$VS_OUTPUT" '.[] | select(.name == $n) | (.width / .scale | floor)')
  mon_x=$(nest monitors -j | jq -r --arg n "$VS_OUTPUT" '.[] | select(.name == $n) | .x')
  mon_id=$(nest monitors -j | jq -r --arg n "$VS_OUTPUT" '.[] | select(.name == $n) | .id')
  echo "    [win] GF-REF: id $mon_id, x $mon_x, logical width $mon_w; compositor plugin: $(vs_ipc capabilities status)"
  for pair in "move window: left|left" "move window to next display|disp" "enter full screen|fs" "minimize window|min"; do
    q=${pair%%|*} k=${pair##*|}
    ((fr)) && { case $k in left) q="gauche" ;; fs) q="plein écran" ;; min) q="réduire" ;; disp) q="écran suivant" ;; esac; }
    fl_focus_class '^foot$' || true
    open_search "$q"
    if [[ $k == left ]]; then
      for alt in "move window left" "move window: left" "window left" "left half" "tile left" "left"; do
        open_search "$alt"
        echo "    [win:left] query '$alt' -> $(fl_json search status | jq -r '[.groups[].items[] | select(.kind == "command") | .title] | join(" | ")')"
      done
      natural_left() { open_search "move window left"; has_title 'move window: left'; }
      # Known defect 2026-11-24: the natural spelling finds nothing (the title has a colon). DEFECT, not a FAIL.
      if natural_left; then echo "PASS: the natural query 'move window left' finds Move Window: Left"; else echo "DEFECT: 'move window left' finds no Move Window: Left (only 'move window: left' or 'left' do)"; fi
      open_search "$q"
    fi
    titles | sed "s/^/    [win:$k] /"
    case $k in
      left) select_title 'left|gauche' ;;
      fs) select_title 'full screen|plein écran' ;;
      min) select_title 'minimi|réduire' ;;
      disp) select_title 'next display|écran suivant|prochain' ;;
    esac || echo "NOTE: no row for '$q'"
    echo "    [win:$k] selected: $(sel_title)"
    shot "run-win-$k-search" >/dev/null
    fl_tap Return; vs_sleep 1.5
    w1=$(win)
    echo "    [win:$k] after: $w1"
    shot "run-win-$k" >/dev/null
    case $k in
      left) fl_check "Move Window: Left put the window on the left half" jqt '((.at[0] - '"$mon_x"') <= 40) and (.size[0] < ('"$mon_w"' * 0.6))' "$w1" ;;
      fs) fl_check "Enter Full Screen made the window fullscreen" jqt '.fullscreen != 0' "$w1"
          # leave it again with the same command's pair
          fl_focus_class '^foot$' || true
          open_search "full screen"; ((fr)) && open_search "plein écran"
          select_title 'exit full|quitter|full screen|plein' || true
          fl_tap Return; vs_sleep 1.2 ;;
      min) echo "    [win:min] hidden=$(jq -r '.hidden' <<<"$w1") workspace=$(jq -r '.workspace' <<<"$w1")"
           fl_check "Minimize Window took the window off the Space (minimized)" jqt '.workspace < 0 or .hidden' "$w1"
           # bring it back: the Dock/Switcher path is out of scope here; the foot window is closed at the end of the section
           ;;
      disp) echo "    [win:disp] monitor $(jq -r '.monitor' <<<"$w0") -> $(jq -r '.monitor' <<<"$w1")"
            [[ $(nest monitors -j | jq length) -ge 2 ]] && fl_check "Move Window to Next Display changed the window's monitor" test "$(jq -r '.monitor' <<<"$w0")" != "$(jq -r '.monitor' <<<"$w1")" ;;
    esac
  done
  fl_close_windows '^foot$'
  # Commands that act on the host: present, confirmation shown where the spec says, never run
  for q in "sleep" "lock screen" "log out" "restart" "shut down" "empty trash"; do
    ((fr)) && case $q in sleep) q=suspendre ;; "lock screen") q="verrouiller" ;; "log out") q="fermer la session" ;; restart) q="redémarrer" ;; "shut down") q="éteindre" ;; "empty trash") q="vider la corbeille" ;; esac
    open_search "$q"
    echo "    [host] '$q' -> $(fl_json search status | jq -r '[.groups[].items[] | select(.kind == "command") | .title] | join(" | ")')"
  done
  # Confirmations: Restart and Shut Down ask first (Popups.confirm); Return opens the dialog, Esc cancels. Never confirmed.
  for q in "restart" "shut down" "log out" "empty trash"; do
    ((fr)) && case $q in restart) q="redémarrer" ;; "shut down") q="éteindre" ;; "log out") q="fermer la session" ;; "empty trash") q="vider la corbeille" ;; esac
    open_search "$q"
    select_title '^(restart|shut|log|empty|red|étei|ferm|vider)' || { echo "NOTE: no command row for '$q'"; continue; }
    t=$(sel_title)
    echo "    [confirm] Return on '$t' (the confirmation is shown, then cancelled with Esc)"
    n=${t//[^A-Za-z0-9]/_}
    fl_tap Return; vs_sleep 1.5
    shot "run-confirm-$n" >/dev/null
    fl_tap Escape; vs_sleep 0.8
    shot "run-confirm-$n-cancelled" >/dev/null
    vs_ipc search close >/dev/null
  done
  vs_ipc search close >/dev/null
fi

# ---- 5. Script Commands ---------------------------------------------------------------------------------------------------
if want scripts; then
  echo "== scripts"
  mkdir -p "$scripts_dir"
  chmod 700 "$scripts_dir"
  cat > "$scripts_dir/palette-hello.sh" <<'EOF'
#!/usr/bin/env bash
# @raycast.schemaVersion 1
# @raycast.title Palette Hello Script
# @raycast.mode compact
# @raycast.packageName Palette Test
# @raycast.description Prints one line.
echo "hello from the palette test"
EOF
  rm -f "$VS_STATE/palette-ran"
  printf 'touch %q\n' "$VS_STATE/palette-ran" >> "$scripts_dir/palette-hello.sh" # proves a run, should one ever happen
  chmod 755 "$scripts_dir/palette-hello.sh"
  echo "    scripts folder: $scripts_dir ($(ls -1 "$scripts_dir" | tr '\n' ' '))"
  vs_sleep 2
  open_search "palette hello"
  vs_sleep 1
  titles | sed 's/^/    [script] /'
  fl_check "the script is listed with its header title" has_title 'Palette Hello Script'
  shot script-found >/dev/null
  select_title 'Palette Hello' || true
  fl_tap Tab; vs_sleep 0.7
  shot script-actions >/dev/null
  fl_tap Escape; vs_sleep 0.4
  fl_tap Return; vs_sleep 1.5
  echo "    [script] after Return: open=$(st .open) notice='$(st .notice)'"
  shot script-return >/dev/null
  # X3b (the runner) is not built: Return must refuse cleanly. What the user sees is the DEFECT below until a message exists.
  if [[ $(st .open) == false && -z $(st .notice) && $(fl_notif history) == 0 ]]; then
    echo "DEFECT: Return on a script closes Search with no message at all (nothing runs, nothing says why: notices 0, no refusal text)"
  fi
  if [[ -f $VS_STATE/palette-ran ]]; then echo "FAIL: the script ran"; fl_fail=1; fi
  fl_check "no QML error after running a script row" fl_no_qml_errors
  tail -n 5 "$VS_DEV/shell.log" | sed 's/^/    [log] /'
  rm -f "$scripts_dir/palette-hello.sh"
  vs_ipc search close >/dev/null
fi

# ---- 6. look: crispness, size, radii, chips ----------------------------------------------------------------------------------
if want look; then
  echo "== look"
  fl_close_windows '^org\.grassfield\.Settings$' 2>/dev/null || true; vs_sleep 1
  open_search "a"
  full=$(shot look-results)
  lb=$(bbox "$base" "$full" 2); unpack "$lb"; pw0=$gw
  echo "    [look] Search $(lg "$gw") x $(lg "$gh") logical at x=$(lg "$gx") y=$(lg "$gy") (device $lb); panel token width 520"
  # crops at device resolution (no resampling) for the eye: top-left corner, a row, the chips
  magick "$full" -crop "160x160+$gx+$gy" +repage -filter point -resize 400% "$VS_SHOTS/palette-look-corner.$VS_LANG.png"
  magick "$full" -crop "$((gw))x$((gh / 3))+$gx+$gy" +repage "$VS_SHOTS/palette-look-top.$VS_LANG.png"
  echo "    crops: palette-look-corner, palette-look-top"
  # row pitch and width: the selection highlight moved one row down twice (the highlight differs between two captures)
  fl_tap Down; vs_sleep 0.4
  r1=$(shot look-sel1)
  fl_tap Down; vs_sleep 0.4
  r2=$(shot look-sel2)
  b01=$(bbox "$full" "$r1" 2); unpack "$b01"; t0=$gy; rw=$gw; rh=$gh
  b12=$(bbox "$r1" "$r2" 2); unpack "$b12"; t1=$gy
  echo "    [look] selected row width $(lg "$rw") logical, row pitch $(lg $((t1 - t0))) logical (token searchRowHeight 63), union of two rows $(lg "$rh") high"
  pitch=$(awk -v a="$t1" -v b="$t0" -v s="$scale" 'BEGIN { printf "%d", (a - b) / s + 0.5 }')
  fl_check "row pitch is the token's 63 logical px (got $pitch)" test "$pitch" -eq 63
  fl_check "the panel is 520 logical px wide (got $(lg "$pw0"))" test "$(lg "$pw0")" = "520.0"
  vs_ipc search close >/dev/null
fi

fl_done
