#!/usr/bin/env bash
# scripts/dev/migrated-tree.sh (ADR-0056, review of #37 MEDIUM-1): the migrated UI tree of a development run is built once per
# CONTENT of the sources, never deleted or rewritten while a process may use it, swapped in by one rename, and named by a stamp
# that scripts/dev/shell-run.sh puts in security_sig so that a changed tree restarts the security process on purpose. Offscreen:
# a copy of the sources in a temporary root, no compositor, no process.
set -euo pipefail
root=$(git -C "$(dirname "$0")" rev-parse --show-toplevel)
tmp=$(mktemp -d "${GRASSFIELD_TEST_TMP:-${TMPDIR:-/tmp}}/migtree.XXXXXX")
trap 'rm -rf "$tmp"' EXIT
fail=0
check() { if "$@"; then echo "PASS: $desc"; else echo "FAIL: $desc"; fail=1; fi; }
tool=$root/scripts/dev/migrated-tree.sh

mkdir -p "$tmp/r/scripts/dev" "$tmp/dev"
cp -r "$root/shell" "$tmp/r/shell"
cp "$root/scripts/dev/migrate-qs-imports.py" "$tmp/r/scripts/dev/"
cp "$root/VERSION" "$tmp/r/VERSION"
run() { bash "$tool" "$tmp/r" "$tmp/dev" 2>"$tmp/err"; }

s1=$(run) || { echo "FAIL: the first build"; cat "$tmp/err"; exit 1; }
desc="the first run builds .dev/migrated-<stamp>, a stamp of 16 hex digits, and .dev/migrated is a link to it"
check bash -c '[[ $1 =~ ^[0-9a-f]{16}$ ]] && [[ -L $2/migrated && $(readlink "$2/migrated") == "$2/migrated-$1" && -f $2/migrated-$1/.stamp ]]' _ "$s1" "$tmp/dev"
desc="the tree is the packaged form: a stub shell.qml, shell-core.qml, security.qml kept, links to ../VERSION and ../.dev"
check bash -c 'd=$1/migrated/shell; grep -q LazyLoader "$d/shell.qml" && [[ -f $d/shell-core.qml ]] && grep -q "import qs.security.host" "$d/security.qml" && [[ -L $1/migrated/VERSION ]]' _ "$tmp/dev"

touch "$tmp/dev/migrated-$s1/MARK"
s1b=$(run)
desc="a second run on the same content rebuilds nothing (same stamp, the marker inside the tree is still there)"
check bash -c '[[ $1 == $2 && -f $3/migrated-$1/MARK ]]' _ "$s1" "$s1b" "$tmp/dev"
touch "$tmp/r/shell/security.qml" "$tmp/r/shell/security/lock/LockView.qml" "$tmp/r/shell/shell.qml"
s1c=$(run)
desc="touching the sources changes no content, so nothing is rebuilt (the reload_locked step_nowatch touch is harmless)"
check bash -c '[[ $1 == $2 && -f $3/migrated-$1/MARK ]]' _ "$s1" "$s1c" "$tmp/dev"

printf '// changed\n' >>"$tmp/r/shell/lib/Mode.qml"
s2=$(run)
desc="a changed source gives a new stamp and a fresh directory; the tree a process may use is not deleted (its marker stays), the link moves"
check bash -c '[[ $1 != $2 && -d $3/migrated-$2 && -f $3/migrated-$1/MARK && $(readlink "$3/migrated") == "$3/migrated-$2" ]]' _ "$s1" "$s2" "$tmp/dev"
desc="the new tree carries the change, the old one does not"
check bash -c 'grep -q "^// changed$" "$2/migrated-$3/shell/lib/Mode.qml" && ! grep -q "^// changed$" "$2/migrated-$1/shell/lib/Mode.qml"' _ "$s1" "$tmp/dev" "$s2"

printf '// changed again\n' >>"$tmp/r/shell/lib/Mode.qml"
s3=$(run)
desc="a third content keeps the one before it and removes the older one"
check bash -c '[[ -d $2/migrated-$3 && -d $2/migrated-$4 && ! -e $2/migrated-$1 ]]' _ "$s1" "$tmp/dev" "$s2" "$s3"

# A real directory left by the first version of the launcher is moved aside, not deleted.
rm "$tmp/dev/migrated"; mkdir -p "$tmp/dev/migrated/shell"; touch "$tmp/dev/migrated/OLD"
s3b=$(run)
desc="a real .dev/migrated directory is moved to migrated-legacy (not deleted) and replaced by the link"
check bash -c '[[ -f $1/migrated-legacy/OLD && -L $1/migrated ]]' _ "$tmp/dev"

# A tree that does not migrate leaves the link where it was and no build directory.
printf 'import QtQuick\nimport qs.nothing\nItem {}\n' >"$tmp/r/shell/lib/Broken.qml"
before=$(readlink "$tmp/dev/migrated")
if run >/dev/null; then rc=0; else rc=$?; fi
desc="a source that does not migrate fails (exit 1), the link still points to the last good tree, no build directory is left"
check bash -c '[[ $1 == 1 && $(readlink "$2/migrated") == "$3" && -z $(ls -A "$2" | grep "^.migrated-build") ]]' _ "$rc" "$tmp/dev" "$before"

# The launcher: the tree stamp is in security_sig (a changed tree restarts security), and it never deletes the migrated tree.
sr=$root/scripts/dev/shell-run.sh
desc="shell-run.sh puts the tree stamp in security_sig"
check bash -c 'grep -q "^security_sig=\"migrated=\$migrated tree=\${tree_stamp:-} " "$1"' _ "$sr"
desc="shell-run.sh builds the tree only through migrated-tree.sh and removes no migrated directory itself"
check bash -c 'grep -q "scripts/dev/migrated-tree.sh" "$1" && ! grep -qE "rm -rf .*(\\\$mig|migrated)" "$1"' _ "$sr"
desc="shell-run.sh starts the security process from the same tree as the UI (security_qml follows shell_dir)"
check bash -c 'grep -q "^security_qml=\$shell_dir/security.qml" "$1" && grep -q "setsid qs -p \"\$security_qml\"" "$1"' _ "$sr"
exit "$fail"
