#!/usr/bin/env bash
# ADR-0056 (draft): scripts/dev/migrate-qs-imports.py turns the shell tree into one that file: URLs reach (Qt's QML disk cache
# refuses qs:@ URLs). Checked on a copy of the tree: every `import qs.*` (but security.qml's, which is kept) becomes a relative
# import of a directory that has a qmldir (so a singleton stays one instance: one URL per file), shell.qml becomes a stub that
# carries settings.watchFiles: false and a LazyLoader of its core, a second run changes nothing, the source tree itself is never
# touched, and a core that does not load ends the process by SIGABRT (a failure for systemd, never status 0).
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
desc="the migrated tree has no import of qs left (security.qml apart)"
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
    if p == src / "security.qml":
        continue  # kept as it is: the security process keeps loading it through qs: (ADR-0056 D-5)
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

desc="shell.qml is a stub: watchFiles false, a LazyLoader of shell-core.qml by file: URL, a failed core ends the process by SIGABRT (never status 0)"
check bash -c 'f=$1/shell.qml; grep -q "settings.watchFiles: false" "$f" && grep -q "LazyLoader" "$f" && grep -q "shell-core.qml" "$f" && grep -q "kill -ABRT" "$f" && ! grep -v "^ *//" "$f" | grep -q "Qt.quit()\|Qt.exit(" && ! grep -q "import qs" "$f"' _ "$tmp/shell"
desc="shell-core.qml holds the former root as a Scope, without watchFiles (the stub has it)"
check bash -c 'f=$1/shell-core.qml; grep -q "^Scope {" "$f" && ! grep -q "ShellRoot {" "$f" && ! grep -q "settings.watchFiles" "$f"' _ "$tmp/shell"
desc="security.qml is kept verbatim and no security-core.qml exists (the security process is not migrated yet)"
check bash -c 'cmp -s "$1/shell/security.qml" "$2/security.qml" && [ ! -e "$2/security-core.qml" ]' _ "$root" "$tmp/shell"
desc="the pragma lines of shell.qml are in its stub, as many as in the source"
check bash -c '[ "$(grep -c "^//@" "$1/shell/shell.qml" || true)" = "$(grep -c "^//@" "$2/shell.qml" || true)" ]' _ "$root" "$tmp/shell"
desc="--dry-run (the check-quick step) accepts the whole tree"
check bash -c 'python3 -I "$1" --dry-run >/dev/null' _ "$mig"
desc="--dry-run refuses an import it cannot migrate (a qs module without a qmldir)"
cp -r "$root/shell" "$tmp/broken"
printf 'import QtQuick\nimport qs.nothing\nItem {}\n' >"$tmp/broken/lib/Broken.qml"
check bash -c '! python3 -I "$1" --dry-run --src "$2" >/dev/null 2>&1' _ "$mig" "$tmp/broken"

# The failure path, on a tiny tree under the real qs (offscreen): a core that is there runs and the process stays up; a core
# that is missing (or does not compile) ends the process by SIGABRT (status 134 through a shell), after the stub's 10 s.
if command -v qs >/dev/null; then
  mkdir -p "$tmp/mini/shell" "$tmp/run"
  printf 'import QtQuick\nimport Quickshell\nShellRoot {\n    settings.watchFiles: false\n    Component.onCompleted: console.log("MINI-CORE-RUNS")\n}\n' >"$tmp/mini/shell/shell.qml"
  python3 -I "$mig" --in-place "$tmp/mini/shell" >/dev/null
  qsrun() {
    env -u GRASSFIELD_SESSION -u QT_QPA_PLATFORMTHEME -u WAYLAND_DISPLAY -u HYPRLAND_INSTANCE_SIGNATURE XDG_RUNTIME_DIR="$tmp/run" \
      XDG_CACHE_HOME="$tmp/cache" HOME="$tmp" QT_QPA_PLATFORM=offscreen QS_DISABLE_CRASH_HANDLER=1 QS_DISABLE_FILE_WATCHER=1 \
      bash -c 'ulimit -c 0; timeout 16 qs -n -p "$1" --no-color >"$2" 2>&1; echo "rc=$?" >>"$2"' _ "$1" "$2"
  }
  qsrun "$tmp/mini/shell" "$tmp/ok.log"
  desc="a core that loads runs, and the process stays up (killed by the 16 s timeout, status 124)"
  check bash -c 'grep -q MINI-CORE-RUNS "$1" && grep -qx "rc=124" "$1"' _ "$tmp/ok.log"
  rm "$tmp/mini/shell/shell-core.qml"
  qsrun "$tmp/mini/shell" "$tmp/bad.log"
  desc="a core that did not load: an error line, then the process dies by SIGABRT (status 134), never 0"
  check bash -c 'grep -q "shell-core.qml did not load" "$1" && grep -qx "rc=134" "$1"' _ "$tmp/bad.log"
else
  echo "SKIP: no quickshell (the failure path of the stub)"
fi

# The unit: a transient user service that runs the failing tree is a FAILED unit (killed by SIGABRT), the state that Restart=
# and OnFailure= (the failure counter, ADR-0041 step 1a: tests/shell/shell_failures.sh) act on. Needs a user manager: SKIP
# without one (the sandbox has none).
if command -v systemd-run >/dev/null && systemctl --user show-environment >/dev/null 2>&1 && [[ -d $tmp/mini/shell ]]; then
  unit=gf-migrate-test-$$
  out=$(systemd-run --user --wait --collect --unit "$unit" -p LimitCORE=0 -p Environment=QS_DISABLE_CRASH_HANDLER=1 \
    -p Environment=QT_QPA_PLATFORM=offscreen -p Environment=XDG_CACHE_HOME="$tmp/cache" \
    qs -n -p "$tmp/mini/shell" --no-color 2>&1 || true)
  desc="the unit that ran a tree with a missing core ends failed (killed by SIGABRT), so Restart= and OnFailure= act on it"
  check bash -c 'grep -q "ABRT\|Result: signal\|code=killed" <<<"$1"' _ "$out"
else
  echo "SKIP: no systemd user manager (the failed-unit state of the stub; run bare)"
fi
exit "$fail"
