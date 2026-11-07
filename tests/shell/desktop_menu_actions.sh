#!/usr/bin/env bash
# The desktop menu's file actions (Duplicate, Make Alias, Compress, Clean Up By metadata) on the real DesktopFiles and a
# temporary desktop folder. Runs tests/shell/desktop_menu_actions.d/actions.qml offscreen. Plain shell test: prints
# PASS/FAIL, exits non-zero on failure.
set -euo pipefail
root=$(git -C "$(dirname "$0")" rev-parse --show-toplevel)
cd "$root"
unset QT_QPA_PLATFORMTHEME
mkdir -p "$root/.dev"
tmp=$(mktemp -d "$root/.dev/desktop-menu-actions.XXXXXX")
trap 'rm -rf "$tmp"' EXIT
mkdir -p "$tmp/runtime" "$tmp/home" "$tmp/state" "$tmp/desktop/Docs"
printf 'hello\n' > "$tmp/desktop/Notes.txt"
# Paste Item: a cut file outside the desktop is moved in, a copied one is copied (its source stays); a cut never
# replaces a hidden file of the same name, two cuts of one name in a row both land, and "p/q/.." and "p/q/../q" are refused.
mkdir -p "$tmp/outside/p/q" "$tmp/outside/b" "$tmp/bin"
printf 'moved\n' > "$tmp/outside/Moved.txt"
printf 'kept\n' > "$tmp/outside/Kept.txt"
printf 'desk\n' > "$tmp/desktop/.secret"
printf 'outside\n' > "$tmp/outside/.secret"
printf 'one\n' > "$tmp/outside/Dup.txt"
printf 'two\n' > "$tmp/outside/b/Dup.txt"
# wl-copy is a recorder and wl-paste prints a fixed list ("SAME"): the test sees when the clipboard is emptied, and
# nothing reaches a real clipboard.
printf '#!/bin/sh\nprintf "%%s\\n" "$*" >> "%s"\n' "$tmp/wl-copy.log" > "$tmp/bin/wl-copy"
printf '#!/bin/sh\nprintf SAME\n' > "$tmp/bin/wl-paste"
chmod +x "$tmp/bin/wl-copy" "$tmp/bin/wl-paste"
chmod 700 "$tmp/runtime"
mkdir -p "$tmp/cfg"
for entry in shell/*; do
  [[ $(basename "$entry") == shell.qml ]] || ln -s "$root/$entry" "$tmp/cfg/$(basename "$entry")"
done
cp tests/shell/desktop_menu_actions.d/actions.qml "$tmp/cfg/shell.qml"
out=$(env -u WAYLAND_DISPLAY -u HYPRLAND_INSTANCE_SIGNATURE -u GRASSFIELD_SESSION -u DISPLAY GRASSFIELD_DEV=1 \
  QS_NO_RELOAD_POPUP=1 HOME="$tmp/home" XDG_RUNTIME_DIR="$tmp/runtime" GRASSFIELD_STATE_HOME="$tmp/state" \
  GRASSFIELD_DESKTOP_DIR="$tmp/desktop" GF_TEST_OUTSIDE="$tmp/outside" GF_TEST_WLCOPY_LOG="$tmp/wl-copy.log" PATH="$tmp/bin:$PATH" QT_QPA_PLATFORM=offscreen QML_IMPORT_PATH="$root/ui:$root/.dev/build/qml" \
  GRASSFIELD_LANG=en timeout 60 qs -p "$tmp/cfg" --no-color 2>&1) || true
if grep -q "desktop-menu-actions: PASS" <<<"$out"; then
  grep "desktop-menu-actions:" <<<"$out"
  exit 0
fi
grep -E "desktop-menu-actions:|ERROR|WARN qml" <<<"$out" || echo "$out"
echo "FAIL: tests/shell/desktop_menu_actions.sh"
exit 1
