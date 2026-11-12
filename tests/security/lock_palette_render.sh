#!/usr/bin/env bash
# ADR-0041 S4, the lock draws the dark palette whatever the user's appearance, checked by what it DRAWS (the opus reviews of
# 00eff2bd and of 39670f1f: the static lint, tests/security/lock_palette.py, cannot see every path a colour can take).
# lock_palette_render.d/probe.qml draws the REAL lock surface offscreen under Quickshell: lock_palette_render.d/surface.py
# copies Lock.qml's WlSessionLockSurface block (the ground colour, the view's loader, every binding given to the LockView it
# creates) and its groundOf() into ProbeLockSurface.qml, whose root stands in for the rest of Lock.qml with fixed data (Lock.qml
# holds the session lock and is never loaded here). The scene: one surface with its LockView and all of its real children shown
# (the artwork backdrop, the scrim, the date and clock, the user's lock message from a settings file written here, the initials
# disc, the name, the password field holding a typed password and the keyboard focus, the error line and the notice line), and
# two grounds alone (the view's loader stopped: the surface's first frame), one before its screen is known and one after. Every
# input is the same but the appearance. Pass when:
#   - the scene built with Appearance.dark true and the one built with it false draw the same image, byte for byte, and every
#     colour and URL among the properties of every visible item is the same (for...in over each item: its declared properties
#     too, its grouped and held objects, its palette); the text shadows' MultiEffects are walked with their layers on (the
#     offscreen renderer is Qt's software scene graph, which draws no shader effect: their colours are compared as inputs);
#   - one scene built dark, the appearance flipped to light while it is shown and back, draws the same image throughout;
#   - control: a rectangle in Appearance.colors.text draws differently in the two (the grab sees the appearance).
# The probe refuses to save a scene that is not fully shown (a line missing, a fade not done, an empty field, no focus).
# Then the same against copies of the tree with one colour path that follows the appearance each (mutants); each must make it
# FAIL (see the list at the end). Scratch under .dev/ (removed on exit); the working tree is never edited. Not a dev session's
# fixtures (no wallpaper override, no fixed user): the dev gate only keeps services off the owner's bus. Not exercised: Caps
# Lock's hint (real key events; the same Text as the error line, drawn here) and the caret (it blinks: hidden; its colour is
# the dots', compared). The text shadows' layers are off for the grabs (the software renderer would draw nothing in their
# place), so their output is compared through their inputs only.
# LOCK_RENDER_MUTANTS="<name> ..." runs only those mutants ("none": none); LOCK_RENDER_KEEP=1 keeps the scratch tree.
# Plain shell test: PASS/FAIL lines, non-zero on failure.
set -euo pipefail
root=$(git -C "$(dirname "$0")" rev-parse --show-toplevel)
cd "$root"
unset QT_QPA_PLATFORMTHEME
command -v qs >/dev/null || { echo "SKIP: lock_palette_render needs Quickshell (qs)"; exit 0; }
mkdir -p "$root/.dev"
tmp=$(mktemp -d "$root/.dev/lock-render.XXXXXX")
if [[ ${LOCK_RENDER_KEEP:-} == 1 ]]; then echo "lock palette render: scratch kept in $tmp"; else trap 'rm -rf "$tmp"' EXIT; fi
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
  python3 -I tests/security/lock_palette_render.d/surface.py "$dir/cfg/security/lock/Lock.qml" "$dir/cfg/ProbeLockSurface.qml" || return 3
  # The user's lock message (Settings > Lock Screen > Show message when locked), read by the real Settings.
  mkdir -p "$dir/home/config"
  printf '{"version": 1, "lock": {"showMessage": true, "message": "Back after lunch"}}\n' >"$dir/home/config/grassfield.json"
}

run() { # <dir>: the probe's last line
  local dir=$1
  env -u WAYLAND_DISPLAY -u HYPRLAND_INSTANCE_SIGNATURE -u DISPLAY -u DBUS_SESSION_BUS_ADDRESS -u GRASSFIELD_SESSION \
    -u GRASSFIELD_VISUAL_FIXTURES GRASSFIELD_DEV=1 LOCK_RENDER_OUT="$dir/out" HOME="$dir/home" XDG_RUNTIME_DIR="$dir/runtime" \
    XDG_CACHE_HOME="$dir/home/.cache" XDG_CONFIG_HOME="$dir/home/.config" XDG_DATA_HOME="$dir/home/.local/share" \
    XDG_STATE_HOME="$dir/home/.local/state" GRASSFIELD_STATE_HOME="$dir/home/state" GRASSFIELD_CONFIG_HOME="$dir/home/config" \
    QT_QPA_PLATFORM=offscreen QML_IMPORT_PATH="$dir/ui:$root/.dev/build/qml" GRASSFIELD_LANG=en \
    timeout 150 qs -p "$dir/cfg" --no-color >"$dir/log" 2>&1 || true
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

tree "$tmp/control" || { echo "FAIL: lock palette render: the probe's surface cannot be made from Lock.qml (lock_palette_render.d/surface.py: stale)"; exit 1; }
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
  [[ -z ${LOCK_RENDER_MUTANTS:-} || " $LOCK_RENDER_MUTANTS " == *" $name "* ]] || return 0
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
  [[ ${LOCK_RENDER_KEEP:-} == 1 ]] || rm -rf "$dir"
}
lock=security/lock/Lock.qml
# Round 4 (the opus review of 00eff2bd): paths a lint can miss.
mutant icon-default-tint "cfg/$view" @END "    Icon {\n        x: 10\n        y: 10\n        name: \"lock\"\n        size: 24\n    }\n"
mutant script-module-colour ui/Grassfield/Ui/GlassTint.js ".pragma library\n" ".pragma library\n.import Grassfield.Ui as Ui\n\nfunction probe() {\n    return Ui.Appearance.colors.text;\n}\n" \
  "cfg/$view" @END "    Rectangle {\n        x: 40\n        y: 10\n        width: 24\n        height: 24\n        color: GlassTint.probe()\n    }\n"
mutant template-literal-colour "cfg/$view" @END "    Rectangle {\n        x: 70\n        y: 10\n        width: 24\n        height: 24\n        color: \`\${Appearance.colors.text}\`\n    }\n"
# Round 5 (the opus review of 39670f1f, MINOR, items 1-5): each path a user sees that only the lint covered.
mutant focus-ring-left-on "cfg/$view" "                focusRing: false\n" ""
mutant shadow-colour "cfg/$view" "shadowColor: Appearance.darkColors.shadow" "shadowColor: Appearance.colors.text"
mutant notice-colour "cfg/$view" "text: root.notice\n            color: root.colors.text" "text: root.notice\n            color: Appearance.colors.text"
mutant lock-message-colour "cfg/$view" "maximumLineCount: 2\n            elide: Text.ElideRight\n            horizontalAlignment: Text.AlignHCenter\n            color: root.colors.text" \
  "maximumLineCount: 2\n            elide: Text.ElideRight\n            horizontalAlignment: Text.AlignHCenter\n            color: Appearance.colors.text"
mutant shader-own-tint "cfg/$view" @END "    ShaderEffect {\n        x: 100\n        y: 10\n        width: 24\n        height: 24\n        property color tint: Appearance.colors.text\n    }\n"
mutant ground-colour "cfg/$lock" "            color: Tokens.colorDark.shadow\n            property bool groundTaken: false" "            color: Appearance.colors.text\n            property bool groundTaken: false"
mutant ground-of "cfg/$lock" "return root.stills ? root.stills.ground : Tokens.sessionGround;" "return root.stills ? root.stills.ground : String(Appearance.colors.text);"
mutant item-beside-the-view "cfg/$lock" "            LockViewLoader {\n                id: content" \
  "            Rectangle {\n                z: 1\n                x: 130\n                y: 10\n                width: 24\n                height: 24\n                color: Appearance.colors.text\n            }\n            LockViewLoader {\n                id: content"
mutant item-in-the-view-as-created "cfg/$lock" "                sourceComponent: LockView {\n                    id: view\n" \
  "                sourceComponent: LockView {\n                    id: view\n                    Rectangle {\n                        x: 160\n                        y: 10\n                        width: 24\n                        height: 24\n                        color: Appearance.colors.text\n                    }\n"

# The probe's own guard (the opus review of 39670f1f, NIT on probe.qml:48): a scene that is not fully shown is never
# compared. Each of these must make the probe refuse, with its reason.
refused() { # <name> <reason> <file> <find> <replace>
  local name=$1 reason=$2 dir=$tmp/$1 out
  shift 2
  [[ -z ${LOCK_RENDER_MUTANTS:-} || " $LOCK_RENDER_MUTANTS " == *" $name "* ]] || return 0
  tree "$dir" "$@" || { echo "FAIL: lock palette render guard $name does not apply (stale)"; fail=1; return; }
  out=$(run "$dir")
  if [[ $out == *"lock-render: ERROR"*"$reason"* ]]; then
    echo "PASS: lock palette render guard $name: the probe refuses ($out)"
  else
    echo "FAIL: lock palette render guard $name: the probe did not refuse with '$reason' ($out)"
    fail=1
  fi
  [[ ${LOCK_RENDER_KEEP:-} == 1 ]] || rm -rf "$dir"
}
refused field-left-empty "the password was not typed" cfg/security/PasswordField.qml "        readOnly: root.busy\n" "        readOnly: root.busy\n        maximumLength: 0\n"
refused focus-elsewhere "does not have the keyboard focus" "cfg/$view" "        focusField();\n        root.shown = true;" "        root.shown = true;"
refused notice-hidden "is not fully shown" "cfg/$view" "visible: root.notice !== \"\"" "visible: false"
exit "$fail"
