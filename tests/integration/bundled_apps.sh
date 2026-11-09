#!/usr/bin/env bash
# The bundled apps (ADR-0055), data only, nothing started:
#   A  grassfield-desktop depends on grassfield-sanaga and grassfield-notes (the packages' names, ADR-0033 b.6)
#   B  the Dock's default pins are one list in the schema, the generated defaults, the Dock model and the store:
#      sanaga, grassfield-notes, foot, org.grassfield.Settings; the earlier default still reads as it
#   C  the contract desktop entries (sanaga.desktop: text/html, xhtml, http, https; grassfield-notes.desktop: text/markdown,
#      text/x-markdown) name their binary and never a launcher that resolves the default browser again (omarchy-launch-browser,
#      xdg-open, omarchy-browser: the fork storm of 2026-10-30)
# C reads the entries from the sibling repositories' packaging directories at GRASSFIELD_SANAGA_DIR / GRASSFIELD_NOTES_DIR
# (default ~/workspace/sanaga and ~/workspace/grassfield-notes) and SKIPs when they are not there.
set -uo pipefail
root=$(git -C "$(dirname "$0")" rev-parse --show-toplevel)
unset GRASSFIELD_SESSION QT_QPA_PLATFORMTHEME
fail=0
ok() { echo "PASS: $1"; }
bad() { echo "FAIL: $1"; fail=1; }

# A
desktop_depends=$(awk '/^package_grassfield-desktop\(\)/{f=1} f && /^  depends=\(/{print; exit}' "$root/packaging/arch/PKGBUILD")
words=" ${desktop_depends//[()]/ } "
for dep in grassfield-sanaga grassfield-notes; do
  [[ $words == *" $dep "* ]] && ok "A grassfield-desktop depends on $dep" || bad "A grassfield-desktop lacks $dep"
done
[[ $words == *" sanaga "* ]] && bad "A depends names the bare sanaga (only grassfield-* names are in the channel)" || ok "A no bare sanaga in depends"
[[ $words == *" hyprland="* || $words == *" hyprland>"* || $words == *" hyprland<"* ]] && bad "A hyprland is constrained" || ok "A hyprland is never constrained"

# B
want='sanaga,grassfield-notes,foot,org.grassfield.Settings'
schema=$(python3 -I -c 'import json,sys; d=json.load(open(sys.argv[1])); print(",".join(d["properties"]["dock"]["properties"]["pinned"]["default"]))' "$root/config/schema/grassfield.schema.json")
defaults=$(python3 -I -c 'import json,sys; print(",".join(json.load(open(sys.argv[1]))["dock"]["pinned"]))' "$root/config/defaults/grassfield.json")
model=$(sed -n 's/^const DEFAULT_PINNED = \[\(.*\)\];/\1/p' "$root/shell/dock/DockModel.js" | tr -d '" ')
for pair in "schema:$schema" "defaults:$defaults" "DockModel:$model"; do
  [[ ${pair#*:} == "$want" ]] && ok "B ${pair%%:*} default pins are $want" || bad "B ${pair%%:*} default pins are ${pair#*:}"
done
store="$root/shell/store/SettingsStore.qml"
if grep -qF 'old === "chromium\nfoot\norg.grassfield.Settings"' "$store" && grep -qF '["sanaga", "grassfield-notes", "foot", "org.grassfield.Settings"]' "$store"; then
  ok "B the store migrates the earlier default"
else
  bad "B the store does not migrate the earlier default"
fi
python3 "$root/scripts/dev/gen-settings.py" --check >/dev/null 2>&1 && ok "B generated defaults are current" || bad "B generated defaults are stale"

# C
check_entry() { # file id types
  local file=$1 id=$2 types=$3 line cmd t
  [[ -f $file ]] || { echo "SKIP: C $id entry not found ($file)"; return; }
  while read -r line; do
    cmd=${line%% *}
    cmd=${cmd##*/}
    case $cmd in
      omarchy-launch-browser | omarchy-browser | xdg-open | gio | xdg-settings | uwsm-app | sh | bash | env) bad "C $id has a handler that can resolve itself again: $line" ;;
      "${id%.desktop}") ok "C $id Exec runs its own binary ($cmd)" ;;
      *) bad "C $id Exec runs $cmd" ;;
    esac
  done < <(sed -n 's/^Exec=//p' "$file")
  for t in $types; do
    grep -q "^MimeType=\(.*;\)\?$t;" "$file" && ok "C $id handles $t" || bad "C $id lacks $t"
  done
}
check_entry "${GRASSFIELD_SANAGA_DIR:-$HOME/workspace/sanaga}/packaging/sanaga.desktop" sanaga.desktop "text/html application/xhtml+xml x-scheme-handler/http x-scheme-handler/https"
check_entry "${GRASSFIELD_NOTES_DIR:-$HOME/workspace/grassfield-notes}/packaging/grassfield-notes.desktop" grassfield-notes.desktop "text/markdown text/x-markdown"
exit "$fail"
