#!/usr/bin/env bash
# Hyprland's own parser reports an error of the user's input.lua at that file and line, not at a Grassfield file that wrapped the
# call: with a scratch HOME whose ~/.config/hypr/input.lua sets two unknown keys, `Hyprland --verify-config` on session.lua names
# ".../hypr/input.lua:1" and ":2" (review of eda12be2: a hl.config wrapper in omarchy.lua had moved both to omarchy.lua:90).
# Omarchy is a tree of fakes (OMARCHY_PATH), so the include reaches the user's files on any machine.
# Needs Hyprland and its headers (as `just check-config`); SKIP otherwise.
set -euo pipefail
root=$(git -C "$(dirname "$0")" rev-parse --show-toplevel)
if ! command -v Hyprland >/dev/null || [[ ! -r /usr/include/hyprland/src/version.h ]]; then echo "SKIP: no Hyprland: error lines NOT VERIFIED"; exit 0; fi
tmp=$(mktemp -d "${GRASSFIELD_TEST_TMP:-${TMPDIR:-/tmp}}/config-error-lines.XXXXXX")
trap 'rm -rf "$tmp"' EXIT
fail=0
check() { if "$@"; then echo "PASS: $desc"; else echo "FAIL: $desc"; fail=1; fi; }
commit=$(sed -n 's/^#define[[:space:]]*GIT_COMMIT_HASH[[:space:]]*"\([0-9a-f]*\)".*/\1/p' /usr/include/hyprland/src/version.h)
mkdir -p "$tmp/home/.config/hypr" "$tmp/run" "$tmp/omarchy/default/hypr"
printf 'hl.config({ input = { not_a_key_one = 1 } })\nhl.config({ input = { not_a_key_two = 2 } })\n' > "$tmp/home/.config/hypr/input.lua"
# A tree of fakes for Omarchy's two modules the include needs before it loads the user's files (omarchy.lua), marked as the other
# tests' fakes are: the case never depends on an installed Omarchy (OMARCHY_PATH points here).
: >"$tmp/omarchy/grassfield-fake-omarchy"
printf 'o = o or {}\n' >"$tmp/omarchy/default/hypr/helpers.lua"
: >"$tmp/omarchy/default/hypr/envs.lua"
: >"$tmp/omarchy/default/hypr/input.lua"
out=$(env HOME="$tmp/home" XDG_RUNTIME_DIR="$tmp/run" OMARCHY_PATH="$tmp/omarchy" HYPRLAND_INSTANCE_SIGNATURE="${commit:-0000000}_0_verify" GRASSFIELD_CONFIG_DIR="$root/config/hypr" \
  Hyprland --verify-config --config "$root/config/hypr/session.lua" 2>&1 || true)
echo "$out" | grep -E "input\.lua|omarchy\.lua" | sed 's/^/    /' || true
desc="an unknown key of the user's input.lua is reported at input.lua:1"
check grep -q "hypr/input\.lua:1:" <<<"$out"
desc="and the second at input.lua:2"
check grep -q "hypr/input\.lua:2:" <<<"$out"
desc="no error of the user's file is blamed on a Grassfield file (omarchy.lua)"
check bash -c '! grep -q "omarchy\.lua:[0-9]*: .*not_a_key" <<<"$1"' _ "$out"
exit $fail
