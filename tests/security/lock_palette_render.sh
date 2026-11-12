#!/usr/bin/env bash
# ADR-0041 S4, the lock draws the dark palette whatever the user's appearance, checked by what it DRAWS (the opus review of
# 00eff2bd: the static lint, tests/security/lock_palette.py, cannot see every path a colour can take: a script module
# reached through a qualifier or a variable, a template literal, a nested block). lock_palette_render.d/probe.qml draws the
# REAL lock surface content (shell/security/lock/LockView.qml with its real children: the artwork backdrop, the scrim, the
# date and clock, the initials disc, the name, the password field with a password typed, the error line) offscreen under
# Quickshell, with every input the same but the appearance, and saves the grabs. Pass when:
#   - the view built with Appearance.dark true and the one built with it false draw the same image, byte for byte, and every
#     visible item has the same colour inputs (the offscreen renderer is Qt's software scene graph, which draws no shader
#     effect: an Icon's tint or a MultiEffect's colour is compared by its input);
#   - one view built dark, the appearance flipped to light while it is shown and back, draws the same image throughout;
#   - control: a rectangle in Appearance.colors.text draws differently in the two (the grab sees the appearance).
# Then the same against copies of the tree with one colour path that follows the appearance each (mutants); each must make
# it FAIL: an Icon with its default tint in LockView, a script module's colour (GlassTint.js importing Grassfield.Ui), a
# template literal's colour. Scratch under .dev/ (removed on exit); the working tree is never edited. Not a dev session's
# fixtures (no wallpaper override, no fixed user): the dev gate only keeps services off the owner's bus. Caps Lock is not
# exercised (it needs real key events; its line is the same Text as the error line drawn here), nor the caret (it blinks:
# the keyboard is taken off the field; its colour is the dots' colour, which is compared). The text shadow (MultiEffect) draws
# nothing offscreen: the probe turns its layers off so the date, the clock, the name and the lock message are drawn and compared.
# Plain shell test: PASS/FAIL lines, non-zero on failure.
set -euo pipefail
root=$(git -C "$(dirname "$0")" rev-parse --show-toplevel)
cd "$root"
unset QT_QPA_PLATFORMTHEME
command -v qs >/dev/null || { echo "SKIP: lock_palette_render needs Quickshell (qs)"; exit 0; }
mkdir -p "$root/.dev"
tmp=$(mktemp -d "$root/.dev/lock-render.XXXXXX")
trap 'rm -rf "$tmp"' EXIT
fail=0

# tree <dir> [<file> <find> <replace>]...: a config directory with the probe as shell.qml; the real modules linked, or, with
# mutations, copies of shell/ and ui/ with each one applied (a literal \n in a find or a replace is a line break; the find
# @END puts the replace before the file's last closing brace, so a mutant item is drawn above the others).
tree() {
  local dir=$1 entry name
  shift
  mkdir -p "$dir/runtime" "$dir/home" "$dir/out" "$dir/cfg"
  chmod 700 "$dir/runtime"
  if [[ $# -eq 0 ]]; then
    for entry in "$root"/shell/*; do
      name=$(basename "$entry")
      [[ $name == shell.qml || $name == security.qml ]] || ln -s "$entry" "$dir/cfg/$name"
    done
    ln -s "$root/ui" "$dir/ui"
  else
    cp -a "$root/shell/." "$dir/cfg/"
    rm -f "$dir/cfg/security.qml"
    cp -a "$root/ui" "$dir/ui"
    ln -s "$root/branding" "$dir/branding" # ui/Grassfield/Ui/icons is a relative link into branding/
    while [[ $# -ge 3 ]]; do
      python3 -I - "$dir/$1" "$2" "$3" <<'PY' || return 3
import sys
path, old, new = sys.argv[1:4]
old, new = old.replace("\\n", "\n"), new.replace("\\n", "\n")
text = open(path).read()
if old == "@END":
    end = text.rstrip().rfind("}")
    if end < 0:
        sys.exit(3)
    open(path, "w").write(text[:end] + new + text[end:])
    sys.exit(0)
if text.count(old) != 1:
    sys.exit(3)
open(path, "w").write(text.replace(old, new))
PY
      shift 3
    done
  fi
  cp tests/security/lock_palette_render.d/probe.qml "$dir/cfg/shell.qml"
}

run() { # <dir>: the probe's last line
  local dir=$1
  env -u WAYLAND_DISPLAY -u HYPRLAND_INSTANCE_SIGNATURE -u DISPLAY -u DBUS_SESSION_BUS_ADDRESS -u GRASSFIELD_SESSION \
    -u GRASSFIELD_VISUAL_FIXTURES GRASSFIELD_DEV=1 LOCK_RENDER_OUT="$dir/out" HOME="$dir/home" XDG_RUNTIME_DIR="$dir/runtime" \
    XDG_CACHE_HOME="$dir/home/.cache" GRASSFIELD_STATE_HOME="$dir/home/state" GRASSFIELD_CONFIG_HOME="$dir/home/config" \
    QT_QPA_PLATFORM=offscreen QML_IMPORT_PATH="$dir/ui:$root/.dev/build/qml" GRASSFIELD_LANG=en \
    timeout 120 qs -p "$dir/cfg" --no-color >"$dir/log" 2>&1 || true
  grep -m1 -E "lock-render: (DONE|ERROR)" "$dir/log" || echo "lock-render: no verdict"
}

same() { cmp -s "$1/out/$2" "$1/out/$3"; }

# verdict <dir>: "" when the lock drew the same image in both appearances and the control differs, else why not.
verdict() {
  local dir=$1 why=""
  for f in dark light flip-before flip-light flip-back control-dark control-light; do
    [[ -s $dir/out/$f.png ]] || why+="no $f.png; "
    [[ -s $dir/out/$f.colours ]] || why+="no $f.colours; "
  done
  [[ -n $why ]] && { echo "$why"; return; }
  same "$dir" dark.png light.png || why+="built light, the lock draws another image than built dark; "
  same "$dir" flip-before.png flip-light.png || why+="flipped to light while shown, the image changed; "
  same "$dir" flip-before.png flip-back.png || why+="flipped back to dark, the image changed; "
  same "$dir" dark.colours light.colours || why+="built light, a colour input differs ($(diff "$dir/out/dark.colours" "$dir/out/light.colours" | grep "^>" | head -1)); "
  same "$dir" flip-before.colours flip-light.colours || why+="flipped to light while shown, a colour input changed; "
  same "$dir" control-dark.png control-light.png && why+="control: the grab does not see the appearance; "
  same "$dir" control-dark.colours control-light.colours && why+="control: the colour inputs do not see the appearance; "
  echo "$why"
}

tree "$tmp/control"
out=$(run "$tmp/control")
if [[ $out == *"lock-render: DONE"* ]]; then
  why=$(verdict "$tmp/control")
  if [[ -z $why ]]; then
    echo "PASS: lock palette render: the lock draws the same image built light and built dark, and when flipped while shown ($(stat -c %s "$tmp/control/out/dark.png") bytes); the control differs"
  else
    echo "FAIL: lock palette render: $why"
    fail=1
  fi
else
  echo "FAIL: lock palette render: $out"
  sed -n '1,40p' "$tmp/control/log"
  fail=1
fi
python3 -I tests/ci/qml_warnings.py <"$tmp/control/log" && echo "PASS: lock palette render: no QML runtime error" || { echo "FAIL: lock palette render: QML runtime errors"; fail=1; }

view=security/lock/LockView.qml
mutant() { # <name> <file> <find> <replace> [...]
  local name=$1 dir=$tmp/$1 out why
  shift
  tree "$dir" "$@" || { echo "FAIL: lock palette render mutant $name does not apply (stale)"; fail=1; return; }
  out=$(run "$dir")
  if [[ $out != *"lock-render: DONE"* ]]; then
    echo "FAIL: lock palette render mutant $name: the probe did not finish ($out)"
    sed -n '1,20p' "$dir/log"
    fail=1
  else
    why=$(verdict "$dir")
    if [[ -n $why && $why != *"control:"* && $why != *"no "* ]]; then
      echo "PASS: lock palette render mutant $name is caught ($why)"
    else
      echo "FAIL: lock palette render mutant $name is not caught (${why:-the same image in both appearances})"
      fail=1
    fi
  fi
  rm -rf "$dir"
}
mutant icon-default-tint "cfg/$view" @END "    Icon {\n        x: 10\n        y: 10\n        name: \"lock\"\n        size: 24\n    }\n"
mutant script-module-colour ui/Grassfield/Ui/GlassTint.js ".pragma library\n" ".pragma library\n.import Grassfield.Ui as Ui\n\nfunction probe() {\n    return Ui.Appearance.colors.text;\n}\n" \
  "cfg/$view" @END "    Rectangle {\n        x: 40\n        y: 10\n        width: 24\n        height: 24\n        color: GlassTint.probe()\n    }\n"
mutant template-literal-colour "cfg/$view" @END "    Rectangle {\n        x: 70\n        y: 10\n        width: 24\n        height: 24\n        color: \`\${Appearance.colors.text}\`\n    }\n"
exit "$fail"
