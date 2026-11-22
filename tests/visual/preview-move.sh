#!/usr/bin/env bash
# Moving the Preview windows (owner report on 1.0.0-rc9, "the Preview window cannot be moved"): a press on the empty space of
# the viewer's toolbar and of the Glance's header and a drag of 200,100 move the window by about that delta (Qt's drag
# threshold makes it lag by up to 10 px: tolerance 12), as a macOS window moves by its title bar. The viewer with an image and
# with a Markdown file (rendered), then the Glance of the same files; captures of each after the move.
# Standalone (not part of `just visual`: no baselines). Run as a BARE command: tests/visual/preview-move.sh
# Shots: .dev/visual/shots/pm-*.en.png. Exit 1 when a window did not follow the drag.
source "$(dirname "$0")/lib.sh"
vs_session

fix=$VS_DEV/preview-move
mkdir -p "$fix"
[[ -f $fix/picture.png ]] || magick -size 1200x800 gradient:'#d9453d'-'#2f5fd0' "$fix/picture.png"
cat > "$fix/notes.md" <<'MD'
# Release notes

Grassfield **Preview** shows a Markdown file *rendered*, as Quick Look does.

## What changed

- Headings, lists and `inline code`
- [A link](https://grassfield.site) and a picture next to the file:

![A gradient](picture.png)

| Column | Value |
|--------|-------|
| one    | 1     |
| two    | 2     |

```sh
echo "a code block"
```
MD

read -r mon_x mon_y < <("$VS_ROOT/scripts/nestctl" monitors -j | jq -r --arg o "$VS_OUTPUT" '.[] | select(.name == $o) | "\(.x) \(.y)"')
# "<x> <y> <w> <h>" of the client of class $1, relative to the output (logical px, as scripts/dev/pointer.sh takes them).
geom() {
  "$VS_ROOT/scripts/nestctl" clients -j | jq -r --arg c "$1" --argjson mx "$mon_x" --argjson my "$mon_y" \
    '[.[] | select(.class == $c)][0] | "\(.at[0] - $mx) \(.at[1] - $my) \(.size[0]) \(.size[1])"'
}
fail=0
# drag <class> <x offset of the press in the window> <y offset> <label>
drag() {
  local x0 y0 w0 h0 x1 y1 w1 h1 px py dx dy
  read -r x0 y0 w0 h0 < <(geom "$1")
  px=$((x0 + $2)) py=$((y0 + $3))
  # The pointer comes over the window first, as a hand does: a press sent right after a warp onto a window that just mapped
  # can reach the client before its pointer enter and be lost (seen on the Glance, 2026-11-22: no press in the app's log).
  vs_pointer abs "$px" "$py" sleep 300 abs $((px + 1)) "$py" sleep 300 down drag $((px + 200)) $((py + 100)) sleep 80 up sleep 600 >/dev/null
  read -r x1 y1 w1 h1 < <(geom "$1")
  dx=$((x1 - x0 - 200)) dy=$((y1 - y0 - 100))
  if [[ ${dx#-} -le 12 && ${dy#-} -le 12 && $w1 == "$w0" && $h1 == "$h0" ]]; then
    echo "PASS: $4: moved by ($((x1 - x0)),$((y1 - y0))), want about (200,100)"
  else
    echo "FAIL: $4: moved by ($((x1 - x0)),$((y1 - y0))) size ${w0}x${h0} -> ${w1}x${h1}, want about (200,100)" >&2
    fail=1
  fi
}

vs_reset light
vs_spawn "$VS_DEV/build/grassfield-preview" "$fix/picture.png"
vs_wait_clients 1
vs_sleep 2
# The toolbar's middle, between the title and the tools (y: the toolbar row's centre).
read -r _ _ w _ < <(geom org.grassfield.Preview)
drag org.grassfield.Preview $((w / 2)) 26 "viewer (image), empty toolbar space"
vs_capture pm-viewer-image-light

vs_reset light
vs_spawn "$VS_DEV/build/grassfield-preview" "$fix/notes.md"
vs_wait_clients 1
vs_sleep 2
read -r _ _ w _ < <(geom org.grassfield.Preview)
drag org.grassfield.Preview $((w / 2)) 26 "viewer (Markdown), empty toolbar space"
vs_capture pm-viewer-markdown-light

vs_reset dark
vs_spawn "$VS_DEV/build/grassfield-preview" "$fix/notes.md"
vs_wait_clients 1
vs_sleep 2
vs_capture pm-viewer-markdown-dark

vs_reset light
vs_spawn "$VS_DEV/build/grassfield-preview" --glance "$fix/notes.md"
vs_wait_clients 1
vs_sleep 2
read -r _ _ w _ < <(geom org.grassfield.Preview.Glance)
drag org.grassfield.Preview.Glance $((w / 2)) 20 "Glance (Markdown), header"
vs_capture pm-glance-markdown-light

vs_reset light
vs_spawn "$VS_DEV/build/grassfield-preview" --glance "$fix/picture.png"
vs_wait_clients 1
vs_sleep 2
read -r _ _ w _ < <(geom org.grassfield.Preview.Glance)
drag org.grassfield.Preview.Glance $((w / 2)) 20 "Glance (image), header"
vs_capture pm-glance-image-light
vs_reset dark
exit "$fail"
