#!/usr/bin/env bash
# Runs an offscreen harness on a staged shell (stage.sh): [STAGE_SED=...] run.sh NAME MODULE...  runs tests/shell/NAME.d/harness.qml with the
# modules named staged, on an offscreen output with a name (OFF-1, 1920x1080), as a dev session with scratch state. Prints the
# harness's "NAME: PASS ..." as PASS, anything else as FAIL; exits non-zero on failure.
set -euo pipefail
root=$(git -C "$(dirname "$0")" rev-parse --show-toplevel)
name=$1
shift
label=${name//_/-}
command -v qs >/dev/null || { echo "SKIP: $label (qs not installed)"; exit 0; }
tmp=$(mktemp -d "${GRASSFIELD_TEST_TMP:-${TMPDIR:-/tmp}}/$label.XXXXXX")
trap 'rm -rf "$tmp"' EXIT
"$root/tests/shell/panel_stub.d/stage.sh" "$root" "$tmp/shell" "$@"
# The harness: its harness.qml (the staged shell's shell.qml; not named shell.qml in the tree, where test.sh would run it
# unstaged), and files of its own for a staged module (NAME.d/<module>/, registered by <module>/qmldir.extra).
cp -r "$root/tests/shell/$name.d/." "$tmp/shell/"
mv "$tmp/shell/harness.qml" "$tmp/shell/shell.qml"
for extra in "$tmp"/shell/*/qmldir.extra; do
  [[ -f $extra ]] || continue
  cat "$extra" >>"${extra%.extra}"
  rm "$extra"
done
cat >"$tmp/screens.json" <<'JSON'
{"screens": [{"name": "OFF-1", "x": 0, "y": 0, "width": 1920, "height": 1080, "logicalDpi": 96, "logicalBaseDpi": 96, "dpr": 1}]}
JSON
mkdir -p -m 700 "$tmp/runtime" "$tmp/cache" "$tmp/state" "$tmp/config"
out=$(env -u WAYLAND_DISPLAY -u HYPRLAND_INSTANCE_SIGNATURE -u DBUS_SESSION_BUS_ADDRESS -u GRASSFIELD_SESSION -u QT_QPA_PLATFORMTHEME \
  GRASSFIELD_DEV=1 GRASSFIELD_STATE_HOME="$tmp/state" GRASSFIELD_CONFIG_HOME="$tmp/config" HOME="$tmp" \
  QT_QPA_PLATFORM="offscreen:configfile=$tmp/screens.json" QML_IMPORT_PATH="$root/ui:$root/.dev/build/qml" \
  GRASSFIELD_TRANSLATIONS_DIR="$root/.dev/translations" GRASSFIELD_LANG=en XDG_RUNTIME_DIR="$tmp/runtime" XDG_CACHE_HOME="$tmp/cache" \
  timeout 150 qs -p "$tmp/shell" --no-color 2>&1) || true
line=$(grep -oE "$label: (PASS|FAIL).*" <<<"$out" | head -1 || true)
if [[ $line == "$label: PASS"* ]]; then
  echo "PASS: $line"
  exit 0
fi
grep -E "TypeError|ReferenceError|Error:|$label" <<<"$out" | head -20 || true
echo "FAIL: ${line:-$label: no verdict}"
exit 1
