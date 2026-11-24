#!/usr/bin/env bash
# ADR-0067 D-3, slice X3a: packaging/bin/grassfield-script-run (the runner's outer part) against a fake systemd-run and a fake
# systemctl that record their argv and stdin (checks in script_run.d/check.py): the unit's argv, the approvals-file check by the
# runner's own read, the script read once and hashed, the framed message, the output caps, the timeout and lock kills. No real
# unit is ever started here.
set -euo pipefail
root=$(git -C "$(dirname "$0")" rev-parse --show-toplevel)
tmp=$(mktemp -d "${GRASSFIELD_TEST_TMP:-${TMPDIR:-/tmp}}/script-run.XXXXXX")
trap 'rm -rf "$tmp"' EXIT
for v in $(compgen -e); do
  case $v in GRASSFIELD_* | LC_* | LANG | LANGUAGE) unset "$v" ;; esac
done
python3 -I "$root/tests/shell/script_run.d/check.py" "$root" "$tmp"
