#!/usr/bin/env bash
# Owner report 2026-11-22: Settings > Desktop & Dock > Default Apps (web browser, email reader, terminal, one popup per kind of
# document) and Files' first-class New Terminal at Folder (the folder background's context menu), captured in the nested session
# at the owner's scale, 1.25 (GRASSFIELD_REF_SCALE; a session already up keeps its own scale: the note says which).
# Nothing is chosen: the captures show the rows and the menu; the choices are covered by tests/unit (tst_settingsdesktop,
# tst_filesbrowser, tst_backend). The apps run isolated (scripts/dev/isolated.sh through vs_spawn), never on the owner's files.
# Checks: the windows open; the accessibility tree has the rows (a11y-lib.sh).
# Captures: $VS_SHOTS/flow-default-apps-*.<lang>.png.
# Run (bare command; starts a nested session when none is up): tests/visual/default-apps.sh [en|fr]
export VISUAL_LANG=${1:-${VISUAL_LANG:-en}}
export GRASSFIELD_REF_SCALE=${GRASSFIELD_REF_SCALE:-1.25}
source "$(dirname "$0")/flow-lib.sh"
source "$(dirname "$0")/a11y-lib.sh"
fl_start default-apps light
trap 'a11y_stop; fl_cleanup' EXIT
a11y_start || { echo "FAIL: no accessibility bus on the nested private bus (see $VS_STATE/a11y-launcher.log)"; exit 1; }
fl_note "output scale: $("$VS_ROOT/scripts/nestctl" monitors -j | jq -r --arg n "$VS_OUTPUT" '.[] | select(.name == $n) | .scale')"

settings=$VS_DEV/build/grassfield-settings
files=$VS_DEV/build/grassfield-files
[[ -x $settings ]] || { echo "FAIL: $settings missing (run apps/settings/build-direct.sh)"; exit 1; }
[[ -x $files ]] || { echo "FAIL: $files missing (run apps/files/build-direct.sh)"; exit 1; }

# 1. Settings > Desktop & Dock, scrolled to Default Apps.
sclass='^org\.grassfield\.Settings$'
vs_pointer abs 960 540 sleep 100 click >/dev/null
vs_spawn env QT_LINUX_ACCESSIBILITY_ALWAYS_ON=1 "$settings" --section=desktop
fl_check_wait "Settings opens on Desktop & Dock" 30 fl_has_window "$sclass"
spid=$(fl_clients "$sclass" | head -n 1 | cut -f1)
read -r sx sy sw sh <<<"$("$VS_ROOT/scripts/nestctl" clients -j | jq -r '[.[] | select(.class == "org.grassfield.Settings")][0] | "\(.at[0]) \(.at[1]) \(.size[0]) \(.size[1])"')"
ox=$("$VS_ROOT/scripts/nestctl" monitors -j | jq -r --arg n "$VS_OUTPUT" '.[] | select(.name == $n) | .x')
cx=$((sx - ox + sw * 2 / 3))
cy=$((sy + sh / 2))
# Three captures down the page (the groups' place depends on the window's height at this scale).
for part in 1 2 3; do
  for _ in 1 2 3 4 5 6; do vs_pointer abs "$cx" "$cy" scroll 1 >/dev/null; vs_sleep 0.1; done
  vs_sleep 0.6
  FL_NOPARK=1 fl_shot "settings-$part" >/dev/null
  # The rows are "showing" for the accessibility tree once scrolled into the pane.
  if [[ $part == 2 ]]; then
    fl_check "the Default terminal popup is there" a11y_find "$spid" 'combo box' '^Default terminal$' --wait 10
    fl_check "the Documents popup is there" a11y_find "$spid" 'combo box' '^Documents$' --wait 5
  fi
done
fl_close_windows "$sclass" 2>/dev/null || true

# 2. Files: the folder background's context menu.
fclass='^org\.grassfield\.Files$'
folder=$VS_STATE/default-apps-folder
case $folder in "$VS_ROOT"/.dev/visual/default-apps-folder) ;; *) echo "FAIL: unsafe folder path"; exit 1 ;; esac
mkdir -p "$folder/Projects"
vs_spawn "$files" "$folder"
fl_check_wait "Files opens" 30 fl_has_window "$fclass"
fl_focus_class "$fclass"
vs_sleep 1.5
read -r fx fy fw fh <<<"$("$VS_ROOT/scripts/nestctl" clients -j | jq -r '[.[] | select(.class == "org.grassfield.Files")][0] | "\(.at[0]) \(.at[1]) \(.size[0]) \(.size[1])"')"
vs_pointer abs "$((fx - ox + fw * 3 / 4))" "$((fy + fh * 3 / 4))" sleep 200 rclick >/dev/null
vs_sleep 1
FL_NOPARK=1 fl_shot files-background-menu >/dev/null
fl_tap Escape
fl_done
