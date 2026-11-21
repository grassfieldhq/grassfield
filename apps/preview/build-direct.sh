#!/usr/bin/env bash
# Direct build of grassfield-preview with g++ (CMake is not installed yet; see CMakeLists.txt).
# Output: .dev/build/grassfield-preview. The dev binary reads the repository QML directory.
# Usage: apps/preview/build-direct.sh [--install-paths]   (--install-paths bakes /usr/share paths)
#        apps/preview/build-direct.sh --tests             (only the logic unit tests: .dev/build/preview-unit-tests)
# QtPdf/QtPdfQuick and QtMultimedia are QML modules loaded at run time (not linked); they are checked here.
set -euo pipefail
here=$(cd "$(dirname "$0")" && pwd)
root=$(git -C "$here" rev-parse --show-toplevel)
out=$root/.dev/build
mkdir -p "$out"

# GCC 16 warns inside Qt headers (-Wsfinae-incomplete); keep our own warnings visible.
cxxflags=(-std=c++17 -O2 -Wall -Wextra -Wno-sfinae-incomplete -fPIC "-DGRASSFIELD_VERSION=\"$(tr -d "[:space:]" <"$root/VERSION")\"") # VERSION: the one version source

if [[ ${1:-} == "--tests" ]]; then
  # tst_previewapp needs the backend (previewapp.cpp, its moc, Qt Quick for the image provider).
  moc=/usr/lib/qt6/moc
  [[ -x $moc ]] || moc=$(command -v moc-qt6 || command -v moc)
  "$moc" "$here/src/previewapp.h" -o "$out/moc_previewapp_tests.cpp"
  # shellcheck disable=SC2046
  g++ "${cxxflags[@]}" -I"$here/src" -I"$here/../files/src" -I"$here/.." $(pkg-config --cflags Qt6Core Qt6Gui Qt6Qml Qt6Quick) \
    "$root/tests/unit/preview/tst_previewlogic.cpp" "$root/tests/unit/preview/tst_shortcutstyle.cpp" "$root/tests/unit/preview/tst_previewapp.cpp" \
    "$here/src/previewlogic.cpp" "$here/src/previewapp.cpp" "$out/moc_previewapp_tests.cpp" \
    "$here/../files/src/filelogic.cpp" \
    $(pkg-config --libs Qt6Core Qt6Gui Qt6Qml Qt6Quick) -lgtest -lgtest_main -pthread \
    -o "$out/preview-unit-tests"
  echo "built $out/preview-unit-tests"
  exit 0
fi

pkg-config --exists Qt6Pdf Qt6PdfQuick Qt6Multimedia || echo "build-direct: warning: Qt6Pdf/Qt6PdfQuick/Qt6Multimedia missing (PDF and media views need them at run time)" >&2

defs=()
if [[ ${1:-} != "--install-paths" ]]; then
  defs+=("-DGRASSFIELD_PREVIEW_QML_DIR=\"$here/qml\"")
fi

moc=/usr/lib/qt6/moc
[[ -x $moc ]] || moc=$(command -v moc-qt6 || command -v moc)
"$moc" "$here/src/previewapp.h" -o "$out/moc_previewapp.cpp"

# shellcheck disable=SC2046
g++ "${cxxflags[@]}" "${defs[@]}" \
  -I"$here/src" -I"$here/../files/src" -I"$here/.." -I"$root/ui/i18n" -I"$out" \
  $(pkg-config --cflags Qt6Gui Qt6Qml Qt6Quick Qt6DBus) $(pkg-config --cflags wayland-client) -I/usr/include/qt6/QtGui/$(pkg-config --modversion Qt6Gui) -I/usr/include/qt6/QtGui/$(pkg-config --modversion Qt6Gui)/QtGui -I/usr/include/qt6/QtCore/$(pkg-config --modversion Qt6Gui) \
  "$here/src/main.cpp" "$here/src/previewapp.cpp" "$here/src/previewlogic.cpp" "$here/../files/src/filelogic.cpp" "$out/moc_previewapp.cpp" \
  $(pkg-config --libs Qt6Gui Qt6Qml Qt6Quick Qt6DBus) -lwayland-client \
  -o "$out/grassfield-preview"
echo "built $out/grassfield-preview"
