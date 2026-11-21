#!/usr/bin/env bash
# The update helper installs only what it checked (SU-10, docs/specs/updates.md U26): right before the keyring step and right
# before `pacman -Su`, the system's sync databases must still be the checked copies, by their sha256 (a re-hash); another
# `pacman -Sy` that replaced them in between ends the run with exit 9, nothing installed, and the runner says `busy`.
#   1. checked_dbs (the helper's own function, cut out of it) against a temporary pair of folders: identical copies pass; a
#      changed database, a signature gone, a signature that appeared, a database gone, a link in place of a file all fail.
#   2. The helper calls it after no_db_lock and before each pacman run of the transaction, with exit 9.
#   3. grassfield-update-run maps 9 to `busy`.
# Nothing here runs pacman or needs root.
set -uo pipefail
root=$(cd "$(dirname "$0")/../.." && pwd)
helper=$root/packaging/pacman/grassfield-update-helper
runner=$root/packaging/bin/grassfield-update-run
tmp=$(mktemp -d "${GRASSFIELD_TEST_TMP:-${TMPDIR:-/tmp}}/update-checked.XXXXXX")
trap 'rm -rf "$tmp"' EXIT
fails=0
pass() { echo "  ok   $1"; }
fail() { echo "  FAIL $1"; fails=$((fails + 1)); }
expect() { [[ $2 == "$3" ]] && pass "$1" || fail "$1: got '$2', want '$3'"; }

echo "== 1. checked_dbs"
awk '/^sha_of\(\) \{/ { on = 1 } on { print } on && /^}/ { exit }' "$helper" >"$tmp/fn.sh"
awk '/^checked_dbs\(\) \{/ { on = 1 } on { print } on && /^}/ { exit }' "$helper" >>"$tmp/fn.sh"
grep -q '^checked_dbs()' "$tmp/fn.sh" && grep -q '^sha_of()' "$tmp/fn.sh" && pass "checked_dbs (and sha_of) exist in the helper" || { fail "checked_dbs is missing from the helper"; echo "FAIL: update checked dbs"; exit 1; }
reset() {
  rm -rf "$tmp/tmpdb" "$tmp/db"
  mkdir -p "$tmp/tmpdb/sync" "$tmp/db/sync"
  for repo in core extra; do
    printf '%s-db\n' "$repo" >"$tmp/tmpdb/sync/$repo.db"
    cp -p "$tmp/tmpdb/sync/$repo.db" "$tmp/db/sync/$repo.db"
  done
  printf 'sig\n' >"$tmp/tmpdb/sync/core.db.sig"
  cp -p "$tmp/tmpdb/sync/core.db.sig" "$tmp/db/sync/core.db.sig"
}
check() {
  ( repos=(core extra) tmpdb=$tmp/tmpdb dbpath=$tmp/db
    . "$tmp/fn.sh"
    checked_dbs && echo same || echo changed )
}
reset
expect "the checked copies in place: same" "$(check)" same
reset; printf 'newer\n' >"$tmp/db/sync/extra.db"
expect "a database replaced by another pacman -Sy: changed" "$(check)" changed
reset; printf 'core-dc\n' >"$tmp/db/sync/core.db"
expect "the same size, other bytes: changed" "$(check)" changed
reset; rm "$tmp/db/sync/core.db.sig"
expect "the signature gone: changed" "$(check)" changed
reset; printf 'sig\n' >"$tmp/db/sync/extra.db.sig"
expect "a signature the checked copy did not have: changed" "$(check)" changed
reset; rm "$tmp/db/sync/extra.db"
expect "a database gone: changed" "$(check)" changed
reset; rm "$tmp/db/sync/extra.db"; ln -s "$tmp/tmpdb/sync/extra.db" "$tmp/db/sync/extra.db"
expect "a link in place of the database: changed" "$(check)" changed

echo "== 2. the transaction asks it first"
# Each pacman_run of the transaction (the keyring and -Su) is preceded, after no_db_lock, by checked_dbs || finish 9.
n_runs=$(grep -c '^ *pacman_run [01] ' "$helper")
n_checks=$(grep -c '^ *checked_dbs || finish 9 ' "$helper")
expect "two pacman runs in the transaction" "$n_runs" 2
expect "two checks, exit 9" "$n_checks" 2
awk '
  /^ *checked_dbs \|\| finish 9 / { checked = 1; next }
  /^ *no_db_lock$/ { checked = 0; next }
  /^ *pacman_run [01] / { if (!checked) bad = 1; checked = 0 }
  END { exit bad }' "$helper" && pass "each pacman run comes right after its check (none between no_db_lock and it without one)" ||
  fail "a pacman run of the transaction is not preceded by checked_dbs"
grep -q '^# had already become the system.s); 9 the sync databases changed' "$helper" && pass "the helper's header documents exit 9" ||
  fail "the helper's header does not document exit 9"

echo "== 3. the runner"
grep -qE '^  9\) conclude busy ;;$' "$runner" && pass "grassfield-update-run maps 9 to busy" || fail "grassfield-update-run does not map 9 to busy"

echo
if ((fails)); then echo "FAIL: update checked dbs ($fails)"; exit 1; fi
echo "PASS: update checked dbs"
