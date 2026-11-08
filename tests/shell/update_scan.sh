#!/usr/bin/env bash
# rc7 audit R7-SEC-01 (ADR-0033 s5, owner decision SU-M2): grassfield-update-helper gives Omarchy's migrations root through
# its unit's sudo only when none of the run's migrations runs code the person can change. The helper is root-only, so its
# own scan is cut out of it (the word lists, reach() and the classifying loop, as written there) and run against a fixture
# Omarchy tree: a migration that reaches omarchy-hook (directly or through a command), python, git, npm, npx, mise, or that
# sources or runs a script of the home folder counts; the words inside other words, a root path and a plain migration do
# not; the person and root classes are unchanged. Then the decision, read from the source: such a migration keeps the run
# out of the unit before the trial sudo, and the unit's environment drops the person's Python packages and git settings.
# Last, the scan over the installed Omarchy (SKIP without it): it classifies every migration, and the counts are printed.
# The end-to-end case (a rooted migration that calls omarchy-hook goes to the terminal, its sudo never runs) is
# tests/integration/update_migrate.sh (docker).
set -euo pipefail
root=$(git -C "$(dirname "$0")" rev-parse --show-toplevel)
helper=$root/packaging/pacman/grassfield-update-helper
tmp=$(mktemp -d "${GRASSFIELD_TEST_TMP:-${TMPDIR:-/tmp}}/update-scan.XXXXXX")
trap 'rm -rf "$tmp"' EXIT
fail=0
check() { if "$@"; then echo "PASS: update scan: $desc"; else echo "FAIL: update scan: $desc"; fail=1; fi; }

# The helper's scan, cut out of it.
python3 -I - "$helper" >"$tmp/scan.sh" <<'PY'
import re, sys
src = open(sys.argv[1]).read().split("\n")
out = [l for l in src if re.match(r"GU_(PERSON_WORDS|PERSON_EXTRA|ROOT_WORDS|USER_WORDS|USER_EXTRA)=", l)]
start = next(i for i, l in enumerate(src) if l.startswith("  reach() {"))
end = next(i for i in range(start, len(src)) if src[i] == "  }")
out += src[start:end + 1]
start = next(i for i, l in enumerate(src) if l.startswith("  person_words=$(reach "))
end = next(i for i in range(start, len(src)) if src[i] == "  done")
out += src[start:end + 1]
assert len(out) > 30, len(out)
print("\n".join(out))
PY
cat >"$tmp/run.sh" <<'SH'
# run.sh <scan.sh> <migrations folder> <commands folder>...: the classes, one line each.
set -uo pipefail
scan=$1 mig_dir=$2
shift 2
bin_dirs=("$@")
finish() { echo "finish $*"; exit 1; }
pending=()
for path in "$mig_dir"/*.sh; do pending+=("${path##*/}"); done
. "$scan"
echo "needs ${needs[*]}"
echo "rooted ${rooted[*]}"
echo "usercode ${usercode[*]}"
SH

f=$tmp/omarchy
mkdir -p "$f/bin" "$f/migrations"
cmd() { printf '#!/bin/bash\n%s\n' "$2" >"$f/bin/$1"; chmod 755 "$f/bin/$1"; }
cmd omarchy-pkg-add '# omarchy:requires-sudo=true
sudo pacman -S --noconfirm -- "$@"'
# As Omarchy's: the hook's path in a variable first, so that only the word omarchy-hook catches it.
cmd omarchy-hook 'HOOK_PATH="$HOME/.config/omarchy/hooks/$1"
[[ -f $HOOK_PATH ]] && bash "$HOOK_PATH"'
cmd omarchy-theme-set 'omarchy-hook theme-set "$1"'
cmd omarchy-plain 'echo plain'
mig() { printf '%s\n' "$2" >"$f/migrations/$1.sh"; }
mig 100 'omarchy-pkg-add foo'
mig 200 'sudo true
omarchy-hook post-update'
mig 300 'omarchy-theme-set x'
mig 400 "python3 -c 'print(1)'"
mig 410 'python3.13 -m json.tool x'
mig 420 '/usr/bin/python -c 1'
mig 500 'source ~/.config/x.sh'
mig 510 '. "$HOME/.bashrc"'
mig 520 'bash ${XDG_CONFIG_HOME}/x'
mig 600 'git -C ~/.local/share/omarchy pull'
mig 700 'npm install -g x'
mig 710 'npx something'
mig 800 'mise use -g node@lts'
mig 900 'echo hi # github digit legit .gitignore pythonic omarchy-hook-install sh-compatible node'
mig 910 'source /usr/share/omarchy/install/helpers.sh'
mig 950 'gum confirm x'
mig 960 'omarchy-plain'
out=$(bash "$tmp/run.sh" "$tmp/scan.sh" "$f/migrations" "$f/bin")
echo "$out" | sed 's/^/    /'
desc="the person and root classes stay as they were (gum needs a person; sudo, directly or through a command, needs root)"
check grep -qx "needs 950.sh" <<<"$out"
check grep -qx "rooted 100.sh 200.sh" <<<"$out"
desc="code the person can change: omarchy-hook (directly or through a command), python (python3.13, a path), a home script sourced or run, git, npm, npx, mise"
check grep -qx "usercode 200.sh 300.sh 400.sh 410.sh 420.sh 500.sh 510.sh 520.sh 600.sh 700.sh 710.sh 800.sh" <<<"$out"

# The decision, in the source.
desc="such a migration keeps the run out of the unit, before the trial sudo (its reason in the log)"
check python3 -I - "$helper" <<'PY'
import sys
s = open(sys.argv[1]).read()
a = s.index('    if ! in_unit; then\n      why="no systemd unit for this run"\n')
b = s.index('    elif ((${#usercode[@]})); then\n      why="${usercode[*]} would run code the person can change')
c = s.index('    elif ! migrate_unit "$GU_SUDO_DIR/sudo" -n /usr/bin/true; then')
d = s.index('    if [[ -n $why ]]; then\n      for name in "${rooted[@]}"; do outcome+=("needs migration ${name%.sh}"); done\n      finish 7 ')
sys.exit(0 if a < b < c < d else 1)
PY
desc="every scanned migration, rooted or not, is classified for user code (a file grep cannot read counts) and runs in the unit with the others (why the rule covers them all)"
check grep -qxF '    (($? == 1)) || usercode+=("$name")' "$helper"
check grep -qxF "  mapfile -t ordered < <(printf '%s\\n' \"\${!seen[@]}\" | sort)" "$helper"
desc="the unit's environment drops the person's Python packages and git settings (PYTHONNOUSERSITE=1, GIT_CONFIG_GLOBAL=/dev/null)"
check grep -qxF '    --setenv=PYTHONNOUSERSITE=1 --setenv=GIT_CONFIG_GLOBAL=/dev/null' "$helper"

# The installed Omarchy.
if [[ -d /usr/share/omarchy/migrations && -d /usr/share/omarchy/bin ]]; then
  out=$(timeout 120 bash "$tmp/run.sh" "$tmp/scan.sh" /usr/share/omarchy/migrations /usr/bin /usr/share/omarchy/bin) || true
  total=$(find /usr/share/omarchy/migrations -maxdepth 1 -name '*.sh' | wc -l)
  needs=$(sed -n 's/^needs //p' <<<"$out" | wc -w)
  rooted=$(sed -n 's/^rooted //p' <<<"$out" | wc -w)
  user=$(sed -n 's/^usercode //p' <<<"$out")
  user_rooted=$(sed -n 's/^rooted //p' <<<"$out" | tr ' ' '\n' | grep -cxF -f <(tr ' ' '\n' <<<"$user" | grep .) || true)
  echo "    installed Omarchy: $total migrations, needs a person $needs, needs root $rooted (of which $user_rooted run code the person can change), user code in all $(wc -w <<<"$user")"
  desc="the scan reads every migration of the installed Omarchy"
  check bash -c '! grep -q "^finish" <<<"$1" && (($2 > 0 && $3 + $4 <= $2))' _ "$out" "$total" "$needs" "$rooted"
else
  echo "SKIP: update scan: no installed Omarchy"
fi
exit $fail
