#!/usr/bin/env bash
# rc7 audit R7-SEC-01: packaging/pacman/omarchy-migrations.allow, the reviewed Omarchy migrations Software Update may run with
# root without a person (grassfield-update-helper's guarantee), lists every supported Omarchy release whole
# (scripts/dev/omarchy-migrations-allow.py --check). Checks:
#   static    every drift lock (docs/upstream/omarchy*.lock) has its release line, each release exactly its count of lines;
#             controls: a line dropped, a release line dropped, a line twice each fail
#   trees     the installed Omarchy (SKIP unless a drift lock names it) and Omarchy 4.0.6 from pacman's cache (SKIP without
#             it): every migration listed with its sha256 and the class the helper's scans give; control: one allow line
#             with another sha256 fails
#   unknown   a tree whose newest migration is in no drift lock is refused (a release Grassfield does not support yet)
set -euo pipefail
root=$(git -C "$(dirname "$0")" rev-parse --show-toplevel)
tool=$root/scripts/dev/omarchy-migrations-allow.py
list=$root/packaging/pacman/omarchy-migrations.allow
tmp=$(mktemp -d "${GRASSFIELD_TEST_TMP:-${TMPDIR:-/tmp}}/omarchy-allow.XXXXXX")
trap 'rm -rf "$tmp"' EXIT
fail=0
check() { if "$@"; then echo "PASS: omarchy allow: $desc"; else echo "FAIL: omarchy allow: $desc"; fail=1; fi; }
gen() { python3 -I "$tool" "$@" >"$tmp/out" 2>&1; }

desc="every supported release is listed whole (static check)"
check gen --check
desc="the security review's cases: 1792474908 and 1793069744 source excluded migrations (1786643346, 1787494718) and are excluded with them"
check bash -c 'grep -qE "^exclude [0-9a-f]{64} 1792474908\\.sh 4\\.5\\.0-3 " "$1" && grep -qE "^exclude [0-9a-f]{64} 1793069744\\.sh 4\\.5\\.0-3 " "$1" && ! grep -qE "^allow .* (1786643346|1787494718)\\.sh" "$1"' _ "$list"
first_allow=$(grep -m1 -n '^allow ' "$list" | cut -d: -f1)
sed "${first_allow}d" "$list" >"$tmp/dropped"
desc="control: a list with one line dropped fails the static check"
check bash -c '! python3 -I "$1" --check --list "$2" >/dev/null 2>&1' _ "$tool" "$tmp/dropped"
grep -v '^release 4\.0\.6' "$list" >"$tmp/norelease"
desc="control: a list without a supported release's line fails"
check bash -c '! python3 -I "$1" --check --list "$2" >/dev/null 2>&1' _ "$tool" "$tmp/norelease"
{ cat "$list"; grep -m1 '^allow ' "$list"; } >"$tmp/twice"
desc="control: a line twice fails"
check bash -c '! python3 -I "$1" --check --list "$2" >/dev/null 2>&1' _ "$tool" "$tmp/twice"

newest=$(find /usr/share/omarchy/migrations -maxdepth 1 -name '*.sh' -printf '%f\n' 2>/dev/null | sort -n | tail -1)
if [[ -n $newest ]] && grep -qx "# omarchy-newest-migration ${newest%.sh}" "$root"/docs/upstream/omarchy*.lock; then
  desc="the installed Omarchy ($newest): every migration listed with its sha256 and its class"
  check gen --check --tree /
  release=$(sed -n "s/^# omarchy-package //p" "$(grep -lx "# omarchy-newest-migration ${newest%.sh}" "$root"/docs/upstream/omarchy*.lock)")
  python3 -I -c "import re, sys
lines = open(sys.argv[1]).read().split(chr(10))
i = next(i for i, l in enumerate(lines) if l.startswith(\"allow \") and l.split()[3] == sys.argv[2])
lines[i] = re.sub(r\"^allow [0-9a-f]{64}\", \"allow \" + \"0\" * 64, lines[i])
open(sys.argv[3], \"w\").write(chr(10).join(lines))" "$list" "$release" "$tmp/changed"
  desc="control: one allow line of that release with another sha256 fails the tree check"
  check bash -c '! cmp -s "$2" "$3" && ! python3 -I "$1" --check --tree / --list "$3" >/dev/null 2>&1' _ "$tool" "$list" "$tmp/changed"
else
  echo "SKIP: omarchy allow: the installed Omarchy is absent or no drift lock names it (its tree is NOT VERIFIED here)"
fi
pkg=$(ls /var/cache/pacman/pkg/omarchy-4.0.6-*.pkg.tar.zst 2>/dev/null | head -1 || true)
if [[ -n $pkg ]] && command -v bsdtar >/dev/null; then
  desc="Omarchy 4.0.6 ($(basename "$pkg")): every migration listed with its sha256 and its class"
  check gen --check --package "$pkg"
else
  echo "SKIP: omarchy allow: no Omarchy 4.0.6 package in pacman's cache (its tree is NOT VERIFIED here)"
fi

mkdir -p "$tmp/tree/usr/share/omarchy/migrations" "$tmp/tree/usr/share/omarchy/bin" "$tmp/tree/usr/bin"
printf 'echo hi\n' >"$tmp/tree/usr/share/omarchy/migrations/1.sh"
printf '#!/bin/bash\ntrue\n' >"$tmp/tree/usr/share/omarchy/bin/omarchy-x"
gen --check --tree "$tmp/tree" && rc=0 || rc=$?
desc="a tree whose newest migration no drift lock names is refused (exit 2)"
check bash -c '[[ $1 == 2 ]] && grep -q "in no drift lock" "$2"' _ "$rc" "$tmp/out"
exit $fail
