#!/usr/bin/env bash
# Direct build of Grassfield Store with g++ (CMake is not installed yet; see CMakeLists.txt).
# Output: .dev/build/grassfield-store. The dev binary reads the repository QML directory.
# Usage: apps/store/build-direct.sh [--install-paths]   (--install-paths bakes /usr/share paths)
#        apps/store/build-direct.sh --tests [--asan]    (.dev/build/store-unit-tests, or -asan with -fsanitize=address,undefined)
set -euo pipefail
here=$(cd "$(dirname "$0")" && pwd)
root=$(git -C "$here" rev-parse --show-toplevel)
out=$root/.dev/build
mkdir -p "$out"

# GCC 16 warns inside Qt headers (-Wsfinae-incomplete); keep our own warnings visible.
cxxflags=(-std=c++17 -O2 -Wall -Wextra -Wno-sfinae-incomplete -fPIC "-DGRASSFIELD_VERSION=\"$(tr -d "[:space:]" <"$root/VERSION")\"")
moc=/usr/lib/qt6/moc
[[ -x $moc ]] || moc=$(command -v moc-qt6 || command -v moc)
# The backend: every source but the app's own (main.cpp, the screenshot provider, which need Qt Quick).
backend=()
for f in "$here"/src/*.cpp; do
  case $(basename "$f") in main.cpp | screenshotprovider.cpp) ;; *) backend+=("$f") ;; esac
done

if [[ ${1:-} == "--tests" ]]; then
  extra=()
  suffix=""
  if [[ ${2:-} == "--asan" ]]; then
    extra=(-g -fsanitize=address,undefined -fno-omit-frame-pointer)
    suffix="-asan"
  fi
  "$moc" "$here/src/storebackend.h" -o "$out/moc_storebackend$suffix.cpp"
  "$moc" "$here/src/operations.h" -o "$out/moc_operations$suffix.cpp"
  "$moc" "$here/src/storeinstance.h" -o "$out/moc_storeinstance$suffix.cpp"
  "$moc" "$here/../ongoing.h" -o "$out/moc_store_ongoing$suffix.cpp"
  # shellcheck disable=SC2046
  g++ "${cxxflags[@]}" "${extra[@]}" -I"$here/src" -I"$here/.." -I"$root/ui/i18n" \
    "-DSTORE_FIXTURES=\"$root/tests/fixtures/store\"" $(pkg-config --cflags Qt6Core Qt6Gui Qt6Network Qt6DBus Qt6Qml Qt6Quick zlib) \
    "${backend[@]}" "$here/src/screenshotprovider.cpp" "$out/moc_storebackend$suffix.cpp" "$out/moc_operations$suffix.cpp" "$out/moc_storeinstance$suffix.cpp" "$out/moc_store_ongoing$suffix.cpp" \
    "$root"/tests/unit/store/tst_*.cpp \
    $(pkg-config --libs Qt6Core Qt6Gui Qt6Network Qt6DBus Qt6Qml Qt6Quick zlib) -lgtest -lgtest_main -pthread -o "$out/store-unit-tests$suffix"
  echo "built $out/store-unit-tests$suffix"
  exit 0
fi

defs=()
if [[ ${1:-} != "--install-paths" ]]; then
  defs+=("-DGRASSFIELD_STORE_QML_DIR=\"$here/qml\"")
fi
"$moc" "$here/src/storebackend.h" -o "$out/moc_storebackend.cpp"
"$moc" "$here/src/operations.h" -o "$out/moc_operations.cpp"
"$moc" "$here/src/storeinstance.h" -o "$out/moc_storeinstance.cpp"
"$moc" "$here/../ongoing.h" -o "$out/moc_store_ongoing.cpp"
qtver=$(pkg-config --modversion Qt6Gui)
# shellcheck disable=SC2046
g++ "${cxxflags[@]}" "${defs[@]}" \
  -I"$here/src" -I"$here/.." -I"$root/ui/i18n" -I"$out" \
  $(pkg-config --cflags Qt6Gui Qt6Network Qt6Qml Qt6Quick Qt6DBus zlib) $(pkg-config --cflags wayland-client) \
  -I"/usr/include/qt6/QtGui/$qtver" -I"/usr/include/qt6/QtGui/$qtver/QtGui" -I"/usr/include/qt6/QtCore/$qtver" \
  "${backend[@]}" "$here/src/main.cpp" "$here/src/screenshotprovider.cpp" "$out/moc_storebackend.cpp" "$out/moc_operations.cpp" \
  "$out/moc_storeinstance.cpp" "$out/moc_store_ongoing.cpp" $(pkg-config --libs Qt6Gui Qt6Network Qt6Qml Qt6Quick Qt6DBus zlib) -lwayland-client \
  -o "$out/grassfield-store"
echo "built $out/grassfield-store"

# The packaged Store installs its entry and icon (grassfield-store, ADR-0037 SD9); a dev session (scripts/dev/devenv.sh puts .dev/share first in
# XDG_DATA_DIRS) finds its desktop entry and icon here, so the menu bar and Apps name it "Grassfield Store", and Apps starts
# this build. Only under .dev/share, never in the owner's data directories.
if [[ ${1:-} != "--install-paths" ]]; then
  share=$root/.dev/share
  mkdir -p "$share/applications" "$share/icons/hicolor/scalable/apps"
  sed "s|^Exec=grassfield-store$|Exec=$out/grassfield-store|" "$here/org.grassfield.Store.desktop" >"$share/applications/org.grassfield.Store.desktop"
  cp "$root/branding/icons/apps/org.grassfield.Store.svg" "$share/icons/hicolor/scalable/apps/"
fi
