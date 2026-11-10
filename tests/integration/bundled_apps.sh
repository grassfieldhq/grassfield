#!/usr/bin/env bash
# The bundled apps (ADR-0055), data only, nothing started:
#   A  grassfield-desktop depends on grassfield-sanaga and grassfield-notes (the packages' names, ADR-0033 b.6)
#   B  the Dock's default pins are one list in the schema, the generated defaults, the Dock model and the store:
#      sanaga, grassfield-notes, foot, org.grassfield.Settings; the earlier default still reads as it
#   C  the contract desktop entries (sanaga.desktop: text/html, xhtml, http, https; grassfield-notes.desktop: text/markdown,
#      text/x-markdown) name their binary and never a launcher that resolves the default browser again (omarchy-launch-browser,
#      xdg-open, omarchy-browser: the fork storm of 2026-10-30)
# C reads the entries of the PINNED commits (sanaga a9e0e56, grassfield-notes 2daf1c8), vendored byte for byte in
# tests/fixtures/bundled-apps/ and named by the pin: never the HEAD of a sibling checkout, which moves. A re-pin replaces the file
# and the name. When GRASSFIELD_SANAGA_GIT / GRASSFIELD_NOTES_GIT name a clone of the sibling repository, the vendored file is
# also compared with `git show <pin>:packaging/<file>` there (run it bare, from a clone that has the pin).
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
# The store's migration of the earlier defaults is run for real (SettingsStore reading files) by tests/shell/dock_pinned_migration.
[[ -f $root/tests/shell/dock_pinned_migration/shell.qml ]] && grep -q '"chromium","foot","org.grassfield.Settings"\]}}' "$root/tests/shell/dock_pinned_migration/shell.qml" \
  && ok "B the store's migration has its own run (tests/shell/dock_pinned_migration)" || bad "B the store's migration test is missing"
python3 "$root/scripts/dev/gen-settings.py" --check >/dev/null 2>&1 && ok "B generated defaults are current" || bad "B generated defaults are stale"

# C
fixtures=$root/tests/fixtures/bundled-apps
check_entry() { # file id types
  local file=$1 id=$2 types=$3 line cmd t
  [[ -f $file ]] || { bad "C $id: the vendored entry is missing ($file)"; return; }
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
verify_pin() { # vendored file, clone dir, pin, path in the repository
  local vendored=$1 clone=$2 pin=$3 path=$4
  [[ -n $clone ]] || { echo "SKIP: C the vendored $(basename "$vendored") is not compared with $pin (no clone named)"; return; }
  if git -C "$clone" show "$pin:$path" 2>/dev/null | cmp -s - "$vendored"; then
    ok "C the vendored $(basename "$vendored") is byte for byte $path at $pin"
  else
    bad "C the vendored $(basename "$vendored") differs from $path at $pin in $clone (or the clone lacks the pin)"
  fi
}
check_entry "$fixtures/sanaga-a9e0e56.desktop" sanaga.desktop "text/html application/xhtml+xml x-scheme-handler/http x-scheme-handler/https"
check_entry "$fixtures/grassfield-notes-2daf1c8.desktop" grassfield-notes.desktop "text/markdown text/x-markdown"
verify_pin "$fixtures/sanaga-a9e0e56.desktop" "${GRASSFIELD_SANAGA_GIT:-}" a9e0e56 packaging/sanaga.desktop
verify_pin "$fixtures/grassfield-notes-2daf1c8.desktop" "${GRASSFIELD_NOTES_GIT:-}" 2daf1c8 packaging/grassfield-notes.desktop
exit "$fail"
