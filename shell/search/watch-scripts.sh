#!/bin/sh
# Prints one line per change in the given script folders (a file added, removed, moved, rewritten, or its mode changed), until
# killed (ADR-0067 D-3, slice X2). Read only. Arguments: absolute folder paths; the ones that do not exist are left out (the
# shell scans again when Search opens, so a folder made later is noticed). Not recursive: only the folder's own entries are
# script commands. Needs inotifywait (inotify-tools); exits 1 at once without it or without a folder, and the caller then relies
# on scanning when Search opens. Dies with its parent (the shell).
command -v inotifywait >/dev/null 2>&1 || exit 1
for d in "$@"; do
  case $d in /*) [ -d "$d" ] && set -- "$@" "$d" ;; esac
  shift
done
[ "$#" -gt 0 ] || exit 1
if command -v setpriv >/dev/null 2>&1; then
  exec setpriv --pdeathsig TERM -- inotifywait -m -q -e close_write,create,delete,moved_to,moved_from,attrib,delete_self,move_self --format x -- "$@"
fi
exec inotifywait -m -q -e close_write,create,delete,moved_to,moved_from,attrib,delete_self,move_self --format x -- "$@"
