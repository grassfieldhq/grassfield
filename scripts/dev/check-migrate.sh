#!/usr/bin/env bash
# ADR-0056 gate: the shell tree migrates to file: imports (scripts/dev/migrate-qs-imports.py), the migrated copy equals the source
# apart from its import lines (--dry-run verifies it line by line), and the migrated copy passes qmllint on its own (relative
# imports, the stub and the core included). A new file whose import cannot be migrated, or a change of the script that alters
# more than the imports, fails here.
set -euo pipefail
root=$(git -C "$(dirname "$0")" rev-parse --show-toplevel)
cd "$root"
python3 -I scripts/dev/migrate-qs-imports.py --dry-run

tmp=$(mktemp -d)
trap 'rm -rf "$tmp"' EXIT
python3 -I scripts/dev/migrate-qs-imports.py --out "$tmp/shell" >/dev/null
# security.qml is kept as it is and still says `import qs.security.host`: the same qs mapping as scripts/dev/qmllint.sh.
ln -s "$tmp/shell" "$tmp/qs"
sysqml="$tmp/sysqml"
mkdir "$sysqml"
for entry in /usr/lib/qt6/qml/*; do
  [[ ${entry##*/} == Grassfield ]] || ln -s "$entry" "$sysqml/"
done
mapfile -t files < <(find "$tmp/shell" -name '*.qml' | sort)
out="$tmp/qmllint.out"
set +e
/usr/lib/qt6/bin/qmllint --bare -I ui -I "$root/.dev/build/qml" -I "$tmp" -I "$sysqml" --max-warnings -1 "${files[@]}" >"$out" 2>&1
lint_rc=$?
set -e
# The same set-aside as scripts/dev/qmllint.sh (qmllint 6.12's singleton false positive), and nothing else.
false_positive='not declared as singleton in qmldir but using pragma Singleton \[import\]$'
grep -vE "$false_positive" "$out" || true
counted=$(grep -E '^(Warning|Error|Critical): ' "$out" | grep -vcE "$false_positive" || true)
set_aside=$(grep -cE "$false_positive" "$out" || true)
if ((counted > 0)); then
  echo "check-migrate: qmllint of the migrated copy: $counted warning(s)" >&2
  exit 1
fi
if ((lint_rc != 0 && set_aside == 0)); then
  echo "check-migrate: qmllint exit $lint_rc without a warning line" >&2
  exit 1
fi
echo "check-migrate: qmllint of the migrated copy: ${#files[@]} files, 0 warnings ($set_aside singleton false positives set aside)"
