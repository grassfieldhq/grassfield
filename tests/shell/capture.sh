#!/usr/bin/env bash
# ADR-0035 D-10, step 8: packaging/bin/grassfield-capture, Grassfield's screenshots, against fakes of every tool it runs (grim,
# slurp, wl-copy, notify-send, hyprctl, xdg-user-dir, pkill, systemd-run, uwsm-app, gdbus): what it captures, in which colours,
# where and under which name it saves, what it copies, the notice and its "Open in Preview" (checks in capture.d/check.py).
# ADR-0045 OC-1: the capture toolbar's modes and options, screen recording with a fake gpu-screen-recorder, the private state
# the shell watches and `stop` (checks in capture.d/options.py). Nothing here captures a screen, records or reaches a bus.
set -euo pipefail
root=$(git -C "$(dirname "$0")" rev-parse --show-toplevel)
tmp=$(mktemp -d "${GRASSFIELD_TEST_TMP:-${TMPDIR:-/tmp}}/capture.XXXXXX")
trap 'rm -rf "$tmp"' EXIT
for v in $(compgen -e); do
  case $v in GRASSFIELD_* | LC_* | LANG | LANGUAGE) unset "$v" ;; esac
done
rc=0
python3 -I "$root/tests/shell/capture.d/check.py" "$root" "$tmp" || rc=1
python3 -I "$root/tests/shell/capture.d/options.py" "$root" "$tmp" || rc=1
python3 -I "$root/tests/shell/capture.d/shooting.py" "$root" "$tmp" || rc=1
python3 -I "$root/tests/shell/capture.d/text.py" "$root" "$tmp" || rc=1
python3 -I "$root/tests/shell/capture.d/pngscale.py" "$root" "$tmp" || rc=1
python3 -I "$root/tests/shell/capture.d/freeze.py" "$root" "$tmp" || rc=1
exit "$rc"
