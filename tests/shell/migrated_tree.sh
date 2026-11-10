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
desc="a changed source gives a new stamp and a fresh directory; the previous tree is kept whole (its marker stays) and the link moves; processes must be started on the real path (case below), the link only names the current tree"
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

# A process started on the real path of tree A keeps loading from A after the link moves to B; one started through the link does
# not (review of #37, LOW-A). A tiny tree under the real qs (offscreen): its core loads Late.qml with Qt.createComponent 6 s in.
if command -v qs >/dev/null; then
  mkdir -p "$tmp/q/r/scripts/dev" "$tmp/q/dev" "$tmp/q/run"
  mkdir "$tmp/q/r/shell"
  cp "$root/scripts/dev/migrate-qs-imports.py" "$tmp/q/r/scripts/dev/"
  printf 'import QtQuick\nimport Quickshell\nShellRoot {\n    settings.watchFiles: false\n    Timer {\n        id: tm\n        interval: 6000\n        running: true\n        onTriggered: {\n            const c = Qt.createComponent("Late.qml");\n            console.log("LATE=" + c.createObject(tm).tag);\n            Qt.quit();\n        }\n    }\n}\n' >"$tmp/q/r/shell/shell.qml"
  printf 'import QtQuick\nQtObject { property string tag: "V1" }\n' >"$tmp/q/r/shell/Late.qml"
  qtool() { bash "$tool" "$tmp/q/r" "$tmp/q/dev" 2>"$tmp/q/err"; }
  qa=$(qtool)
  real_a=$(readlink -f "$tmp/q/dev/migrated")
  qsq() { # path, log
    env -u GRASSFIELD_SESSION -u QT_QPA_PLATFORMTHEME -u WAYLAND_DISPLAY -u HYPRLAND_INSTANCE_SIGNATURE XDG_RUNTIME_DIR="$tmp/q/run" \
      XDG_CACHE_HOME="$tmp/q/cache" HOME="$tmp/q" QT_QPA_PLATFORM=offscreen QS_DISABLE_CRASH_HANDLER=1 QS_DISABLE_FILE_WATCHER=1 \
      timeout 40 qs -p "$1" --no-color >"$2" 2>&1
  }
  qsq "$real_a/shell" "$tmp/q/real.log" &
  p1=$!
  qsq "$tmp/q/dev/migrated/shell" "$tmp/q/link.log" &
  p2=$!
  sleep 2
  printf 'import QtQuick\nQtObject { property string tag: "V2" }\n' >"$tmp/q/r/shell/Late.qml"
  qb=$(qtool)
  wait "$p1" || true
  wait "$p2" || true
  desc="the swap to tree B happened (new stamp, link points to B)"
  check bash -c '[[ $1 != $2 && $(readlink -f "$3/migrated") != "$4" ]]' _ "$qa" "$qb" "$tmp/q/dev" "$real_a"
  desc="a process started on tree A's real path keeps loading from A after the swap (a late createComponent gives V1)"
  check grep -q 'LATE=V1$' "$tmp/q/real.log"
  desc="a process started through the link loads its late file from B (V2): why every process and every caller uses the real path"
  check grep -q 'LATE=V2$' "$tmp/q/link.log"
  desc="the launchers address the processes by the real path (readlink -f), never the link: shell-run.sh, nested-up.sh, the nested security tests"
  check bash -c 'grep -q "shell_dir=\$(readlink -f \"\$dev/migrated\")/shell" "$1/scripts/dev/shell-run.sh" && grep -q "shell_dir=\$(readlink -f \"\$dev/migrated\")/shell" "$1/scripts/dev/nested-up.sh" && for t in l2_wrong_password lock_keyboard_replaced reload_locked lock_privacy; do grep -q "readlink -f \"\$root/.dev/migrated\"" "$1/tests/security/$t.sh" || exit 1; done' _ "$root"
else
  echo "SKIP: no quickshell (a process on the real path of an old tree keeps loading from it)"
fi

# Two concurrent runs on one content: one build, both succeed with the same stamp, nobody deletes a stamped tree, no leftovers.
rm -rf "$tmp/c"; mkdir -p "$tmp/c/r/scripts/dev" "$tmp/c/dev"
cp -r "$root/shell" "$tmp/c/r/shell"; cp "$root/scripts/dev/migrate-qs-imports.py" "$tmp/c/r/scripts/dev/"
( bash "$tool" "$tmp/c/r" "$tmp/c/dev" >"$tmp/c/o1" 2>"$tmp/c/e1" ) &
( bash "$tool" "$tmp/c/r" "$tmp/c/dev" >"$tmp/c/o2" 2>"$tmp/c/e2" ) &
( bash "$tool" "$tmp/c/r" "$tmp/c/dev" >"$tmp/c/o3" 2>"$tmp/c/e3" ) &
wait
desc="three concurrent runs on one content: the same stamp, one build (one 'file(s) changed' line in all their output), one stamped tree, no temporary directory left"
check bash -c 'cd "$1" && [[ $(cat o1) == $(cat o2) && $(cat o2) == $(cat o3) && $(cat e1 e2 e3 | grep -c "file(s) changed") == 1 && $(ls -d dev/migrated-* | wc -l) == 1 && -f dev/migrated-$(cat o1)/.stamp && -z $(ls -A dev | grep "^\.migrated-\(build\|snap\)") ]]' _ "$tmp/c"
# Concurrent runs on two contents: both finish, the link points at one of them, every stamped tree that is left is whole.
printf '// two\n' >>"$tmp/c/r/shell/lib/Mode.qml"
( bash "$tool" "$tmp/c/r" "$tmp/c/dev" >"$tmp/c/p1" 2>"$tmp/c/f1" ) &
( bash "$tool" "$tmp/c/r" "$tmp/c/dev" >"$tmp/c/p2" 2>"$tmp/c/f2" ) &
wait
desc="two concurrent runs after a change: both succeed with the same new stamp, the link points to it, the previous tree is intact"
check bash -c 'cd "$1" && [[ $(cat p1) == $(cat p2) && $(readlink dev/migrated) == "$1/dev/migrated-$(cat p1)" && -f dev/migrated-$(cat o1)/.stamp && -d dev/migrated-$(cat o1)/shell ]]' _ "$tmp/c"

# A reused tree is verified again; a damaged one is refused and left alone (never deleted by this script).
real_now=$(readlink -f "$tmp/c/dev/migrated")
printf '// tampered\n' >>"$real_now/shell/lib/Mode.qml"
if bash "$tool" "$tmp/c/r" "$tmp/c/dev" >/dev/null 2>"$tmp/c/e4"; then rc=0; else rc=$?; fi
desc="a reused tree that is not the source any more is refused (exit 1, the message names it) and not deleted"
check bash -c '[[ $1 == 1 && -d $2 ]] && grep -q "is not the source apart from its imports" "$3"' _ "$rc" "$real_now" "$tmp/c/e4"

# A source with a symlink is refused, and the link stays where it was.
rm -rf "$tmp/c2"; mkdir -p "$tmp/c2/r/scripts/dev" "$tmp/c2/dev"
cp -r "$root/shell" "$tmp/c2/r/shell"; cp "$root/scripts/dev/migrate-qs-imports.py" "$tmp/c2/r/scripts/dev/"
ln -s /etc/hostname "$tmp/c2/r/shell/lib/Linked"
if bash "$tool" "$tmp/c2/r" "$tmp/c2/dev" >/dev/null 2>"$tmp/c2/err"; then rc=0; else rc=$?; fi
desc="a source with a symlink is refused (exit 1, the message says so) and no tree is published"
check bash -c '[[ $1 == 1 && ! -e $2/dev/migrated ]] && grep -q "symlinks" "$2/err"' _ "$rc" "$tmp/c2"
desc="the stamp is computed from a snapshot of the sources and the tree is built from that snapshot (an edit in between cannot mislabel it)"
check bash -c 'grep -q "cp -a \"\$root/shell\" \"\$snap/shell\"" "$1" && grep -q "cd \"\$snap/shell\" && find" "$1" && grep -q -- "--src \"\$snap/shell\" --out" "$1"' _ "$tool"

# The launcher: the tree stamp is in security_sig (a changed tree restarts security), and it never deletes the migrated tree.
sr=$root/scripts/dev/shell-run.sh
desc="shell-run.sh puts the tree stamp in security_sig"
check bash -c 'grep -q "^security_sig=\"migrated=\$migrated tree=\${tree_stamp:-} " "$1"' _ "$sr"
desc="shell-run.sh builds the tree only through migrated-tree.sh and removes no migrated directory itself"
check bash -c 'grep -q "scripts/dev/migrated-tree.sh" "$1" && ! grep -qE "rm -rf .*(\\\$mig|migrated)" "$1"' _ "$sr"
desc="shell-run.sh starts the security process from the same tree as the UI (security_qml follows shell_dir)"
check bash -c 'grep -q "^security_qml=\$shell_dir/security.qml" "$1" && grep -q "setsid qs -p \"\$security_qml\"" "$1"' _ "$sr"
exit "$fail"
