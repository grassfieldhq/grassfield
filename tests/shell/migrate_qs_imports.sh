#!/usr/bin/env bash
# ADR-0056 (draft): scripts/dev/migrate-qs-imports.py turns the shell tree into one that file: URLs reach (Qt's QML disk cache
# refuses qs:@ URLs). Checked on a copy of the tree: every `import qs.*` becomes a relative import of a directory that has a
# qmldir (so a singleton stays one instance: one URL per file), both roots become stubs that carry settings.watchFiles: false and
# a LazyLoader of their core, a second run changes nothing, and the source tree itself is never touched.
set -euo pipefail
root=$(git -C "$(dirname "$0")" rev-parse --show-toplevel)
tmp=$(mktemp -d "${GRASSFIELD_TEST_TMP:-${TMPDIR:-/tmp}}/migqs.XXXXXX")
trap 'rm -rf "$tmp"' EXIT
fail=0
check() { if "$@"; then echo "PASS: $desc"; else echo "FAIL: $desc"; fail=1; fi; }
mig=$root/scripts/dev/migrate-qs-imports.py

desc="the source tree still has qs imports (it is never migrated in place)"
check bash -c '! python3 -I "$1" --check "$2/shell" >/dev/null' _ "$mig" "$root"
desc="--out migrates a copy of shell/"
check bash -c 'python3 -I "$1" --out "$2" >/dev/null' _ "$mig" "$tmp/shell"
desc="the migrated tree has no import of qs left"
check bash -c 'python3 -I "$1" --check "$2" >/dev/null' _ "$mig" "$tmp/shell"
desc="a second run changes nothing (idempotent) and gives the same tree"
cp -r "$tmp/shell" "$tmp/again"
check bash -c 'python3 -I "$1" --in-place "$2" | grep -q "^migrate-qs-imports: 0 file(s) changed" && diff -r "$3" "$2" >/dev/null' _ "$mig" "$tmp/again" "$tmp/shell"
desc="the same input gives the same output (deterministic)"
python3 -I "$mig" --out "$tmp/second" >/dev/null
check diff -r "$tmp/shell" "$tmp/second"

desc="each import qs.<m> of the source is one relative import of a directory with a qmldir, in the same place"
check python3 -I - "$root/shell" "$tmp/shell" <<'EOF'
import os, re, sys, pathlib
src, out = map(pathlib.Path, sys.argv[1:3])
imp = re.compile(r'^\s*import\s+qs\s*\.\s*([A-Za-z_]\w*(?:\s*\.\s*[A-Za-z_]\w*)*)', re.M)
rel = re.compile(r'^\s*import\s+"([^"]+)"', re.M)
bad = 0
n = 0
for p in sorted(src.rglob("*.qml")):
    mods = [m.replace(" ", "").split(".") for m in imp.findall(p.read_text())]
    q = out / p.relative_to(src)
    if p.parent == src and (out / (p.stem + "-core.qml")).exists():
        q = out / (p.stem + "-core.qml")
    text = q.read_text()
    got = [os.path.normpath(q.parent / r) for r in rel.findall(text)]
    for m in mods:
        want = os.path.normpath(out.joinpath(*m))
        n += 1
        if want not in got or not os.path.isfile(os.path.join(want, "qmldir")):
            print("missing", p, m); bad += 1
print(n, "imports checked")
sys.exit(1 if bad or n < 100 else 0)
EOF

for r in shell security; do
  desc="$r.qml is a stub: watchFiles false, a LazyLoader of $r-core.qml by file: URL, quit when the core did not load"
  check bash -c 'f=$1/$2.qml; grep -q "settings.watchFiles: false" "$f" && grep -q "LazyLoader" "$f" && grep -q "$2-core.qml" "$f" && grep -q "Qt.quit()" "$f" && ! grep -q "import qs" "$f"' _ "$tmp/shell" "$r"
  desc="$r-core.qml holds the former root as a Scope, without watchFiles (the stub has it)"
  check bash -c 'f=$1/$2-core.qml; grep -q "^Scope {" "$f" && ! grep -q "ShellRoot {" "$f" && ! grep -q "settings.watchFiles" "$f"' _ "$tmp/shell" "$r"
done
desc="the pragma lines of the roots are in the stubs, as many as in the sources"
check bash -c 'for r in shell security; do [ "$(grep -c "^//@" "$1/shell/$r.qml" || true)" = "$(grep -c "^//@" "$2/$r.qml" || true)" ] || exit 1; done' _ "$root" "$tmp/shell"
exit "$fail"
