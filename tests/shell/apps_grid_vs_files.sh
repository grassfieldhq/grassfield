#!/usr/bin/env bash
# Files' Applications location lists exactly what the shell's Apps grid shows. The same tree of desktop entries (about 130 files:
# apps_grid/fixtures.py; every shape the 2026-10-25 review found plus the ones measured since) goes through
#   * the grid: Quickshell's own DesktopEntries (the parser the grid uses) run offscreen by apps_grid/probe.qml, then the grid's
#     rules on its result: not noDisplay, not in hidden-entries.sh's output, Model.disambiguate (the real Model.js);
#   * Files: apps/files/src/applicationslogic.cpp, built here against Qt Core only (apps_grid/driver.cpp);
# in two languages, and the lists (id and shown name) must be equal. Mutants of applicationslogic.cpp must break the equality.
# Nothing here touches a session: offscreen Qt, a private HOME and XDG tree, no D-Bus.
set -euo pipefail
root=$(git -C "$(dirname "$0")" rev-parse --show-toplevel)
here=$root/tests/shell/apps_grid
tmp=$(mktemp -d "${GRASSFIELD_TEST_TMP:-${TMPDIR:-/tmp}}/apps-grid.XXXXXX")
trap 'rm -rf "$tmp"' EXIT
fail=0
check() { if "$@"; then echo "PASS: $desc"; else echo "FAIL: $desc"; fail=1; fi; }

if ! command -v qs >/dev/null || ! command -v g++ >/dev/null || [[ ! -f /usr/include/qt6/QtCore/QString ]]; then
  echo "SKIP: apps grid vs Files needs qs, g++ and the Qt 6 headers"
  exit 0
fi

python3 -I "$here/fixtures.py" "$tmp/fx" >/dev/null
mkdir -m 700 "$tmp/rt"
mkdir -p "$tmp/home" "$tmp/cache" "$tmp/cfg"
# The probe is a Quickshell config of its own; Quickshell reads only below the config directory, so the shell is linked in.
sed 's#"../../../../shell/launchpad/Model.js"#"shell/launchpad/Model.js"#; s#"../../../shell/launchpad/Model.js"#"shell/launchpad/Model.js"#' "$here/probe.qml" >"$tmp/cfg/shell.qml"
ln -s "$root/shell" "$tmp/cfg/shell"

xdg_env=(XDG_DATA_HOME="$tmp/fx/home" XDG_DATA_DIRS="$tmp/fx/sys:$tmp/fx/sys2" XDG_CURRENT_DESKTOP=Hyprland)
# grid LANG OUT: "<id>\t<name>" per app of the grid, sorted by id
grid() {
  local hidden
  hidden=$(env "${xdg_env[@]}" sh "$root/shell/launchpad/hidden-entries.sh")
  env -i PATH="$PATH" HOME="$tmp/home" XDG_CACHE_HOME="$tmp/cache" XDG_RUNTIME_DIR="$tmp/rt" "${xdg_env[@]}" LANG="$1" \
    QT_QPA_PLATFORM=offscreen GF_HIDDEN="$hidden" timeout 90 qs -p "$tmp/cfg" 2>&1 |
    sed -n 's/.*GRID|\([^|]*\)|\(.*\)$/\1\t\2/p' | LC_ALL=C sort >"$2"
}
# files DRIVER LANG OUT
files() {
  env -i PATH="$PATH" HOME="$tmp/home" "${xdg_env[@]}" LANG="$2" "$1" | LC_ALL=C sort >"$3"
}
build() { # SOURCE OUT
  g++ -std=c++17 -fPIC -I"$root/apps/files/src" -I/usr/include/qt6 -I/usr/include/qt6/QtCore "$here/driver.cpp" "$1" -lQt6Core -o "$2"
}
build "$root/apps/files/src/applicationslogic.cpp" "$tmp/drv"

for lang in en_US.UTF-8 fr_FR.UTF-8; do
  grid "$lang" "$tmp/grid.$lang"
  files "$tmp/drv" "$lang" "$tmp/files.$lang"
  desc="the grid lists a real set of apps ($lang: $(wc -l <"$tmp/grid.$lang") of the fixture entries)"
  check test "$(wc -l <"$tmp/grid.$lang")" -ge 50
  desc="Files lists exactly the grid's apps with the grid's names ($lang)"
  check diff -u "$tmp/grid.$lang" "$tmp/files.$lang"
done

# Behaviours of the grid that differ from the desktop entry specification or from the earlier Files rules, pinned on the grid's list.
listed() { cut -f1 "$tmp/grid.en_US.UTF-8" | grep -qx -- "$1"; }
desc="the grid lists an entry whose TryExec program is missing (Quickshell does not read TryExec): so does Files"
check listed tryexec-missing
desc="the grid lists a CRLF file and a blank-padded [Desktop Entry] line, and hides '  NoDisplay=true' (Quickshell 0.3.2 trims each line)"
check bash -c 'cut -f1 "$1" | grep -qx crlf && cut -f1 "$1" | grep -qx hdr-lead-space && cut -f1 "$1" | grep -qx hdr-trail-space && ! cut -f1 "$1" | grep -qx lead-ws-nd' _ "$tmp/grid.en_US.UTF-8"
desc="the grid does not list 'Name = x', 'Type = Application' or an entry without a Name (the blanks around '=' are not cut)"
check bash -c '! cut -f1 "$1" | grep -qxE "name-spaced|type-spaced|no-name|name-empty"' _ "$tmp/grid.en_US.UTF-8"
desc="a Categories list that ends in TerminalEmulator without ';' is not a hidden helper (hidden-entries.sh); one with ';' is"
check bash -c 'cut -f1 "$1" | grep -qx term-noslash && ! cut -f1 "$1" | grep -qx term-first' _ "$tmp/grid.en_US.UTF-8"
desc="an entry nested deeper than 8 folders is listed; kde/foo.desktop and kde-foo.desktop give the flat file (the later one of the sorted walk)"
check bash -c 'grep -q "^sub-deep-a-b-c-d-e-f-g-h-i-j-deepest	" "$1" && grep -q "^kde-foo	flat kde-foo$" "$1"' _ "$tmp/grid.en_US.UTF-8"
desc="two apps of one name are told apart: Twin keeps the plain name for Grassfield's own, 'Twin (Vendor)' for a reverse-DNS id, the id otherwise"
check bash -c 'grep -q "^org.grassfield.Twin	Twin$" "$1" && grep -q "^org.vendor.twin	Twin (Vendor)$" "$1" && grep -q "^same-name-a	Twin (same-name-a)$" "$1"' _ "$tmp/grid.en_US.UTF-8"

# Mutants of Files' rules: each must make the list differ from the grid's (untrimmed-lines is Quickshell 0.3.1's reading).
mutant() { # NAME OLD NEW
  python3 -I - "$root/apps/files/src/applicationslogic.cpp" "$tmp/m-$1.cpp" "$2" "$3" <<'PY'
import sys
src, dest, old, new = sys.argv[1:5]
text = open(src).read()
assert old in text, old
open(dest, "w").write(text.replace(old, new, 1))
PY
  build "$tmp/m-$1.cpp" "$tmp/m-$1" 2>/dev/null || return 1
  files "$tmp/m-$1" en_US.UTF-8 "$tmp/m-$1.out"
  ! diff -q "$tmp/grid.en_US.UTF-8" "$tmp/m-$1.out" >/dev/null
}
while IFS='^' read -r name old new; do
  desc="mutation: $name makes Files differ from the grid"
  check mutant "$name" "$old" "$new"
done <<'EOF'
trailing-semicolon-optional^if (!(QLatin1Char(';') + categories).contains(QLatin1String(";TerminalEmulator;")))^if (!categories.contains(QLatin1String("TerminalEmulator")))
untrimmed-lines^const QString line = QString::fromUtf8(raw).trimmed();^const QString line = QString::fromUtf8(raw);
no-disambiguation^    disambiguate(result);^
nodisplay-ignored^    if ((f.noDisplay == QLatin1String("true") && !asked) || f.hidden == QLatin1String("true"))^    if (f.hidden == QLatin1String("true"))
depth-limit^constexpr int kMaxDepth = 32;^constexpr int kMaxDepth = 8;
first-of-a-folder-wins^            winner.insert(file.first, {file.second, text});^            if (!winner.contains(file.first)) winner.insert(file.first, {file.second, text});
invalid-masks^            if (fields.type != QLatin1String("Application") || nameOf(fields, env.locales).isEmpty())^            if (false)
every-desktop-entry-group^            inEntry = !seen && line == QLatin1String("[Desktop Entry]");^            inEntry = line == QLatin1String("[Desktop Entry]");
EOF

exit $fail
