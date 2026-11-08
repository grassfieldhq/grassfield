#!/usr/bin/env bash
# rc7 audit R7-SEC-01 (ADR-0033 s5, owner decision SU-M2): grassfield-update-helper gives Omarchy's migrations root through
# its unit's sudo only when every migration of the run is on Grassfield's reviewed list (the guarantee) and, as defence in
# depth, none of them runs code the person can change. The helper is root-only, so its own code is cut out of it (the word
# lists, reach(), the classifying loop and the list's functions, as written there) and run against a fixture Omarchy tree
# (a package root: usr/share/omarchy/{migrations,bin,install}). The list is made by the real generator
# (scripts/dev/omarchy-migrations-allow.py, --release for a test list): a migration that sources an excluded one is excluded
# (the security review's MAJOR); a listed migration passes for its release; one byte changed in it, in a file it sources or
# in an omarchy-* command it calls, another Omarchy version, an unlisted one, a malformed line (a closure file the helper
# refuses, a closure without the migration, a migration twice), no release line, a list not root's alone: not. The scan: a migration that reaches omarchy-hook (directly or
# through a command), python, git, npm, npx, mise, or that sources or runs a script of the home folder counts; the words
# inside other words, a root path and a plain migration do not; the person and root classes are unchanged. Then the
# decision, read from the source: an unlisted migration, or a missing list, keeps the run out of the unit before the trial
# sudo; the installed file is checked against the list again before it runs; the unit's environment drops the person's
# Python packages and git settings; Grassfield's sudo runs root commands from /, never the caller's folder.
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
# The list functions first (the loop calls them).
out += src[next(i for i, l in enumerate(src) if l.startswith("declare -A gu_allowed=()")):src.index("migrations=$GU_DIR/$op.migrations")]
start = next(i for i, l in enumerate(src) if l.startswith("  reach() {"))
end = next(i for i in range(start, len(src)) if src[i] == "  }")
out += src[start:end + 1]
start = next(i for i, l in enumerate(src) if l.startswith("  person_words=$(reach "))
end = next(i for i in range(start, len(src)) if src[i] == "  done")
out += src[start:end + 1]
assert len(out) > 50, len(out)
print("\n".join(out))
PY
cat >"$tmp/run.sh" <<'SH'
# run.sh <scan.sh> <migrations folder> <commands folder>...: the classes, one line each.
set -uo pipefail
scan=$1 mig_dir=$2
shift 2
bin_dirs=("$@")
finish() { echo "finish $*"; exit 1; }
# The list's place, whether it is root's alone (a test cannot make root's files), the tree its closures are hashed in and
# the Omarchy version being installed: from the caller.
GU_ALLOW=${TEST_ALLOW:-/nonexistent}
root_alone() { [[ ${TEST_ROOT_ALONE:-1} == 1 ]]; }
scan_root=${TEST_ROOT:-/nonexistent}
omarchy_version=${TEST_VERSION:-9.9.9-1}
pending=()
for path in "$mig_dir"/*.sh; do pending+=("${path##*/}"); done
. "$scan"
echo "needs ${needs[*]}"
echo "rooted ${rooted[*]}"
echo "usercode ${usercode[*]}"
echo "allow_ok $allow_ok"
echo "unlisted ${unlisted[*]}"
SH

f=$tmp/root/usr/share/omarchy
mkdir -p "$f/bin" "$f/migrations" "$f/install" "$tmp/root/usr/bin"
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
printf 'echo helper\n' >"$f/install/helpers.sh"
mig 970 'source "$OMARCHY_PATH/install/helpers.sh"'
mig 980 'echo "an allowed-looking migration"
source "$OMARCHY_PATH/migrations/400.sh"'
out=$(bash "$tmp/run.sh" "$tmp/scan.sh" "$f/migrations" "$f/bin")
echo "$out" | sed 's/^/    /'
desc="the person and root classes stay as they were (gum needs a person; sudo, directly or through a command, needs root)"
check grep -qx "needs 950.sh" <<<"$out"
check grep -qx "rooted 100.sh 200.sh" <<<"$out"
desc="code the person can change: omarchy-hook (directly or through a command), python (python3.13, a path), a home script sourced or run, git, npm, npx, mise"
check grep -qx "usercode 200.sh 300.sh 400.sh 410.sh 420.sh 500.sh 510.sh 520.sh 600.sh 700.sh 710.sh 800.sh" <<<"$out"

# The list (the guarantee), made by the generator from this tree.
list=$tmp/allow
python3 -I "$root/scripts/dev/omarchy-migrations-allow.py" --tree "$tmp/root" --release 9.9.9-1 --list "$list" >/dev/null
allowed_set=$(awk '$1 == "allow" { print $3 }' "$list" | tr '\n' ' ')
desc="the generator: a migration that sources an excluded one (980 sources 400, python) is excluded; one that sources an allowed install script (970, 910) is allowed with that script in its closure"
check bash -c '[[ $1 == "100.sh 910.sh 960.sh 970.sh " ]] && grep -qx "exclude [0-9a-f]\{64\} 980.sh 9.9.9-1 home-code" "$2" && grep -q "^allow [0-9a-f]\{64\} 970.sh 9.9.9-1 usr/share/omarchy/install/helpers.sh usr/share/omarchy/migrations/970.sh$" "$2" && grep -q "^allow [0-9a-f]\{64\} 960.sh 9.9.9-1 usr/share/omarchy/bin/omarchy-plain usr/share/omarchy/migrations/960.sh$" "$2"' _ "$allowed_set" "$list"
others="200.sh 300.sh 400.sh 410.sh 420.sh 500.sh 510.sh 520.sh 600.sh 700.sh 710.sh 800.sh 900.sh 950.sh 980.sh"
unlisted_of() { TEST_ROOT=$tmp/root bash "$tmp/run.sh" "$tmp/scan.sh" "$f/migrations" "$f/bin" | sed -n "s/^$1 //p"; }
desc="the helper: the listed migrations pass for their release; every other one is unlisted, an exclude line too"
check test "$(TEST_ALLOW=$list unlisted_of allow_ok):$(TEST_ALLOW=$list unlisted_of unlisted)" == "1:$others"
sed "s/^release 9.9.9-1 /release 9.9.9-0 /" "$list" >"$tmp/allow.otherrelease"
desc="the helper: allow lines of a version that is not one of the list's releases allow nothing"
check test "$(TEST_ALLOW=$tmp/allow.otherrelease unlisted_of allow_ok):$(TEST_ALLOW=$tmp/allow.otherrelease unlisted_of unlisted | wc -w)" == "1:$(ls "$f/migrations" | wc -l)"
desc="the helper: another Omarchy version than the list's releases allows nothing"
check test "$(TEST_ALLOW=$list TEST_VERSION=9.9.9-2 unlisted_of unlisted | wc -w)" == "$(ls "$f/migrations" | wc -l)"
printf '\n' >>"$f/install/helpers.sh"
desc="the helper: one byte added to an install script a listed migration sources makes that migration unlisted (970, 910), the others stay listed"
check bash -c 'u=" $1 "; [[ $u == *" 970.sh "* && $u == *" 910.sh "* && $u != *" 100.sh "* && $u != *" 960.sh "* ]]' _ "$(TEST_ALLOW=$list unlisted_of unlisted)"
printf 'echo helper\n' >"$f/install/helpers.sh"
printf '# a comment\n' >>"$f/bin/omarchy-plain"
desc="the helper: a changed omarchy-* command a listed migration calls makes it unlisted (960)"
check bash -c '[[ " $1 " == *" 960.sh "* ]]' _ "$(TEST_ALLOW=$list unlisted_of unlisted)"
cmd omarchy-plain 'echo plain'
printf '\n' >>"$f/migrations/100.sh"
desc="the helper: one byte added to a listed migration makes it unlisted"
check grep -qw 100.sh <<<"$(TEST_ALLOW=$list unlisted_of unlisted)"
mig 100 'omarchy-pkg-add foo'
check test "$(TEST_ALLOW=$list unlisted_of unlisted)" == "$others"
desc="the list counts only whole: a closure file the helper refuses, a closure without its migration, a migration twice, no release line, a malformed sum, a list not root's alone, no list -> nothing allowed"
first=$(grep -m1 '^allow ' "$list")
{ cat "$list"; echo "${first% *} usr/lib/elsewhere"; } | awk '!seen[$0]++' >"$tmp/allow.outside"
sed -E 's#^(allow [0-9a-f]{64} 960\.sh 9\.9\.9-1) .*#\1 usr/share/omarchy/bin/omarchy-plain#' "$list" >"$tmp/allow.nomig"
{ cat "$list"; grep -m1 '^allow .* 100\.sh ' "$list"; } >"$tmp/allow.twice"
grep -v '^release' "$list" >"$tmp/allow.norelease"
{ cat "$list"; echo "allow nothex 970.sh 9.9.9-1 usr/share/omarchy/migrations/970.sh"; } >"$tmp/allow.bad"
grep -v '^allow' "$list" >"$tmp/allow.none"
got=""
for l in outside nomig twice norelease bad none; do got+="$(TEST_ALLOW=$tmp/allow.$l unlisted_of allow_ok)"; done
got+="$(TEST_ROOT_ALONE=0 TEST_ALLOW=$list unlisted_of allow_ok)$(unlisted_of allow_ok)"
check test "$got" == "00000000"

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
desc="an unreadable list, then an unlisted migration, keep the run out of the unit before the scan's reasons and the trial sudo"
check python3 -I - "$helper" <<'PY'
import sys
s = open(sys.argv[1]).read()
a = s.index('    if ! in_unit; then\n      why="no systemd unit for this run"\n')
b = s.index('    elif ((!allow_ok)); then\n      why="Grassfield\'s list of reviewed Omarchy migrations')
c = s.index('    elif ((${#unlisted[@]})); then\n      why="${unlisted[*]} not in Grassfield\'s list of reviewed Omarchy migrations')
d = s.index('    elif ((${#usercode[@]})); then')
e = s.index('    elif ! migrate_unit "$GU_SUDO_DIR/sudo" -n /usr/bin/true; then')
loop = s.index('    allowed "$scan_root" "$name" "$omarchy_version" || unlisted+=("$name")\n  done')
sys.exit(0 if a < b < c < d < e and loop < a else 1)
PY
desc="the installed file is checked against the list again just before it runs (after the transaction, in the root_alone loop)"
check python3 -I - "$helper" <<'PY'
import sys
s = open(sys.argv[1]).read()
after = s.index("# --- After it (s3.2 step 11, s3.7)")
check = s.index('    if [[ $now_version != "$omarchy_version" ]] || ! allowed "" "$name" "$omarchy_version"; then')
alone = s.index('      if ! root_alone "/$closure_file"; then', check)
run = s.index('  migrate_unit /usr/bin/bash -c "$GU_MIGRATE_LOOP"')
sys.exit(0 if after < check < alone < run else 1)
PY
desc="Grassfield's sudo runs every root command from / (WorkingDirectory=/), never the caller's folder (no --same-dir)"
check bash -c 'grep -qF -- "--uid=\"\$target\" -p WorkingDirectory=/ -p PrivateTmp=yes" "$1" && ! grep -q -- "--same-dir" "$1"' _ "$root/packaging/pacman/grassfield-update-sudo"
desc="the list is installed where the helper reads it (PKGBUILD), and the helper reads that path"
check bash -c 'grep -qF "packaging/pacman/omarchy-migrations.allow\" \"\$pkgdir/usr/share/grassfield/update/omarchy-migrations.allow\"" "$1" && grep -qx "GU_ALLOW=/usr/share/grassfield/update/omarchy-migrations.allow" "$2"' _ "$root/packaging/arch/PKGBUILD" "$helper"
desc="every scanned migration, rooted or not, is classified for user code (a file grep cannot read counts) and runs in the unit with the others (why the rule covers them all)"
check grep -qxF '    (($? == 1)) || usercode+=("$name")' "$helper"
check grep -qxF "  mapfile -t ordered < <(printf '%s\\n' \"\${!seen[@]}\" | sort)" "$helper"
desc="the unit works from / and drops the person's Python packages, modules of the working folder and git settings (WorkingDirectory=/, PYTHONNOUSERSITE=1, PYTHONSAFEPATH=1, GIT_CONFIG_GLOBAL=/dev/null)"
check grep -qxF '    --setenv=PYTHONNOUSERSITE=1 --setenv=PYTHONSAFEPATH=1 --setenv=GIT_CONFIG_GLOBAL=/dev/null' "$helper"
check bash -c 'grep -qF -- "-p KillMode=control-group -p WorkingDirectory=/ -p StandardInput=null" "$1" && ! grep -q "WorkingDirectory=~" "$1"' _ "$helper"
desc="the closure's install scripts are extracted from the new package for the scan (any depth, names of the closure's charset only)"
check grep -qF 'if [[ $member == usr/share/omarchy/install/* && $member != */ ]]; then' "$helper"

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
