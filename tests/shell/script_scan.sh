#!/usr/bin/env bash
# ADR-0067 D-3, slice X2: shell/search/script-scan.py, the file system's half of script discovery, on a scratch folder: every
# refusal of the file checks (not a regular file, not the user's, group- or world-writable, not executable, over 256 KiB, a link
# to a file that fails, a link into a folder others can write, a dangling link) and of the folder check, the skipped names,
# the head read from the open descriptor (checks in script_scan.d/check.py). Lists only; nothing is run.
set -euo pipefail
root=$(git -C "$(dirname "$0")" rev-parse --show-toplevel)
tmp=$(mktemp -d "${GRASSFIELD_TEST_TMP:-${TMPDIR:-/tmp}}/script-scan.XXXXXX")
trap 'rm -rf "$tmp"' EXIT
for v in $(compgen -e); do
  case $v in GRASSFIELD_* | LC_* | LANG | LANGUAGE) unset "$v" ;; esac
done
python3 -I "$root/tests/shell/script_scan.d/check.py" "$root" "$tmp"
