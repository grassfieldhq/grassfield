#!/usr/bin/env bash
# The session-start seed of the bundled apps against the REAL xdg-mime and gio in a scratch HOME (XDG_CURRENT_DESKTOP=
# Grassfield:Hyprland, the session's): Grassfield never writes, edits or deletes a line of the user's own ~/.config/mimeapps.list
# (review of PR #38, HIGH-1), so what a person or an app makes the default survives every start and wins over the seed.
#   A  `xdg-mime default sanaga.desktop x-scheme-handler/http ...` after the seed: the lines stay (replaced in place by xdg-mime, not
#      appended), the next start leaves the file byte for byte, links still open in Sanaga
#   B  Notes' own "open .md with Notes" (xdg-mime default) and `gio mime`: the same
#   C  another browser chosen the same way (Firefox): the lines stay and win, the seeded entries leave the session list
# The seed is compiled from apps/files/src/applicationslogic.cpp with tests/integration/seed_harness.cpp (Qt Core and Gui, g++); the
# script SKIPs without them, without xdg-utils, or without Omarchy's shipped lists. Nothing of the owner's is read or written.
set -uo pipefail
root=$(git -C "$(dirname "$0")" rev-parse --show-toplevel)
unset GRASSFIELD_SESSION QT_QPA_PLATFORMTHEME BROWSER DISPLAY WAYLAND_DISPLAY GRASSFIELD_STATE_HOME
tmp=$(mktemp -d "${GRASSFIELD_TEST_TMP:-${TMPDIR:-/tmp}}/seed-real.XXXXXX")
trap 'rm -rf "$tmp"' EXIT
fail=0
ok() { echo "PASS: $1"; }
bad() { echo "FAIL: $1"; fail=1; }
check() {
  local d=$1
  shift
  if "$@"; then ok "$d"; else bad "$d"; fi
}
for tool in g++ pkg-config xdg-mime; do command -v "$tool" >/dev/null || { echo "SKIP: seed_real_xdg: needs $tool"; exit 0; }; done
pkg-config --exists Qt6Core Qt6Gui || { echo "SKIP: seed_real_xdg: needs Qt 6 development files"; exit 0; }
omarchy=/usr/share/omarchy
[[ -r $omarchy/default/applications/mimeapps.list && -r $omarchy/config/hyprland-mimeapps.list ]] || { echo "SKIP: seed_real_xdg: Omarchy's lists are not installed"; exit 0; }

# shellcheck disable=SC2046
g++ -std=c++17 -O0 -fPIC $(pkg-config --cflags Qt6Core Qt6Gui) -I"$root/apps/files/src" -I"$root/apps" "$root/tests/integration/seed_harness.cpp" "$root/apps/files/src/applicationslogic.cpp" \
  -o "$tmp/seed" $(pkg-config --libs Qt6Core Qt6Gui) -lpthread 2>"$tmp/cc.err" || { echo "SKIP: seed_real_xdg: the harness does not build here"; tail -3 "$tmp/cc.err"; exit 0; }

export HOME=$tmp/home XDG_CONFIG_HOME=$tmp/config XDG_DATA_HOME=$tmp/data XDG_DATA_DIRS=$tmp/share XDG_CONFIG_DIRS=$tmp/etc XDG_STATE_HOME=$tmp/home/.local/state
export XDG_CURRENT_DESKTOP=Grassfield:Hyprland
mkdir -p "$HOME" "$XDG_CONFIG_HOME" "$XDG_DATA_HOME/applications" "$tmp/share/applications" "$tmp/bin"
for n in sanaga chromium firefox; do
  printf '#!/bin/sh\nexit 0\n' >"$tmp/bin/$n"
  chmod +x "$tmp/bin/$n"
  printf '[Desktop Entry]\nType=Application\nName=%s\nExec=%s/bin/%s %%U\nCategories=Network;WebBrowser;\nMimeType=text/html;application/xhtml+xml;x-scheme-handler/http;x-scheme-handler/https;\n' "$n" "$tmp" "$n" >"$tmp/share/applications/$n.desktop"
done
printf '#!/bin/sh\nexit 0\n' >"$tmp/bin/grassfield-notes"
chmod +x "$tmp/bin/grassfield-notes"
printf '[Desktop Entry]\nType=Application\nName=Notes\nExec=%s/bin/grassfield-notes %%F\nMimeType=text/markdown;text/x-markdown;\n' "$tmp" >"$tmp/share/applications/grassfield-notes.desktop"
printf '[Desktop Entry]\nType=Application\nName=Kate\nExec=%s/bin/chromium %%F\nMimeType=text/markdown;text/x-markdown;text/plain;\n' "$tmp" >"$tmp/share/applications/kate.desktop"
cp "$omarchy/default/applications/mimeapps.list" "$XDG_CONFIG_HOME/mimeapps.list"
cp "$omarchy/config/hyprland-mimeapps.list" "$XDG_CONFIG_HOME/hyprland-mimeapps.list"
state=$XDG_STATE_HOME/grassfield/default-apps.state
session=$XDG_CONFIG_HOME/grassfield-mimeapps.list
seed() { "$tmp/seed" "$XDG_CONFIG_HOME" "$state" "$tmp/share/applications" "$omarchy" Grassfield:Hyprland "$tmp/share" >/dev/null; }
query() { xdg-mime query default "$1" 2>/dev/null; }
user_lists() { cat "$XDG_CONFIG_HOME/mimeapps.list" "$XDG_CONFIG_HOME/hyprland-mimeapps.list"; }

seed
check "A the fresh start seeds Sanaga for links" test "$(query x-scheme-handler/http)" = sanaga.desktop
check "A and Notes for Markdown" test "$(query text/markdown)" = grassfield-notes.desktop
before=$(user_lists)
seed
check "A a second start changes no line of the user's lists" test "$before" = "$(user_lists)"

# A: the person (or an app) makes Sanaga the default with xdg-mime, the way a browser or a settings page does
xdg-mime default sanaga.desktop x-scheme-handler/http x-scheme-handler/https text/html >/dev/null 2>&1
check "A xdg-mime default wrote the user's own list" grep -q '^x-scheme-handler/http=sanaga.desktop' "$XDG_CONFIG_HOME/mimeapps.list"
after_xdg=$(cat "$XDG_CONFIG_HOME/mimeapps.list")
seed
check "A the next start leaves the user's mimeapps.list byte for byte" test "$after_xdg" = "$(cat "$XDG_CONFIG_HOME/mimeapps.list")"
check "A ... the http line is still there" grep -q '^x-scheme-handler/http=sanaga.desktop' "$XDG_CONFIG_HOME/mimeapps.list"
check "A ... and links still open in Sanaga" test "$(query x-scheme-handler/http)" = sanaga.desktop
check "A ... and so do pages" test "$(query text/html)" = sanaga.desktop
seed
check "A a third start still writes nothing of the user's" test "$after_xdg" = "$(cat "$XDG_CONFIG_HOME/mimeapps.list")"

# B: Notes' own button (xdg-mime default) and gio mime
xdg-mime default grassfield-notes.desktop text/markdown >/dev/null 2>&1
after_notes=$(cat "$XDG_CONFIG_HOME/mimeapps.list")
seed
check "B the user's text/markdown=grassfield-notes line survives the start" grep -q '^text/markdown=grassfield-notes.desktop' "$XDG_CONFIG_HOME/mimeapps.list"
check "B ... the file is byte for byte" test "$after_notes" = "$(cat "$XDG_CONFIG_HOME/mimeapps.list")"
check "B Markdown opens in Notes" test "$(query text/markdown)" = grassfield-notes.desktop
if command -v gio >/dev/null; then
  gio mime text/x-markdown grassfield-notes.desktop >/dev/null 2>&1
  gio mime x-scheme-handler/https sanaga.desktop >/dev/null 2>&1
  after_gio=$(cat "$XDG_CONFIG_HOME/mimeapps.list")
  seed
  check "B gio mime lines survive the start, byte for byte" test "$after_gio" = "$(cat "$XDG_CONFIG_HOME/mimeapps.list")"
  check "B gio mime text/x-markdown=grassfield-notes.desktop is there" grep -q '^text/x-markdown=grassfield-notes.desktop' "$XDG_CONFIG_HOME/mimeapps.list"
else
  echo "SKIP: B gio is not installed"
fi

# C: another browser chosen with xdg-mime: it wins, the seed leaves the session list, the user's lines stay
xdg-mime default firefox.desktop x-scheme-handler/http x-scheme-handler/https text/html >/dev/null 2>&1
after_ff=$(cat "$XDG_CONFIG_HOME/mimeapps.list")
seed
check "C the user's Firefox lines survive the start" test "$after_ff" = "$(cat "$XDG_CONFIG_HOME/mimeapps.list")"
check "C links open in Firefox, not the seed's Sanaga" test "$(query x-scheme-handler/http)" = firefox.desktop
check "C the seeded Sanaga entries left the session list" bash -c '! grep -q "sanaga.desktop" "$1"' _ "$session"
check "C Notes keeps its own group" grep -q '^text/markdown=grassfield-notes.desktop' "$XDG_CONFIG_HOME/mimeapps.list"
exit "$fail"
