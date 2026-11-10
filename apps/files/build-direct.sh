#!/usr/bin/env bash
# Direct build of grassfield-files with g++ (CMake is not installed yet; see CMakeLists.txt).
# Output: .dev/build/grassfield-files. The dev binary reads the repository QML directory.
# Usage: apps/files/build-direct.sh [--install-paths]   (--install-paths bakes /usr/share paths)
#        apps/files/build-direct.sh --tests             (only the unit tests: .dev/build/files-unit-tests, files-kio-tests)
#        apps/files/build-direct.sh --tests --asan      (the unit tests with -fsanitize=address,undefined: .dev/build/files-unit-tests-asan)
#        apps/files/build-direct.sh --core              (only the Files library: .dev/build/libgrassfield-files-core.a,
#                                                        linked by grassfield-files and apps/portal/build-direct.sh)
set -euo pipefail
here=$(cd "$(dirname "$0")" && pwd)
root=$(git -C "$here" rev-parse --show-toplevel)
out=$root/.dev/build
mkdir -p "$out"

# GCC 16 warns inside Qt headers (-Wsfinae-incomplete); keep our own warnings visible.
cxxflags=(-std=c++17 -O2 -Wall -Wextra -Wno-sfinae-incomplete -fPIC "-DGRASSFIELD_VERSION=\"$(tr -d "[:space:]" <"$root/VERSION")\"") # VERSION: the one version source
# Build against the non-deprecated KF6 API only (also hides deprecated declarations in KIO headers).
kfdefs=(-DKF_DISABLE_DEPRECATED_BEFORE_AND_AT=0x061D00)

# KDE Frameworks 6 ship CMake configs only (no pkg-config files): explicit include dirs and libraries.
kf=/usr/include/KF6
kf_includes=()
for d in KIOCore KIOGui KIOWidgets KIO KCoreAddons KService Solid KJobWidgets; do
  kf_includes+=("-I$kf/$d")
done
kf_libs=(-lKF6KIOCore -lKF6KIOGui -lKF6KIOWidgets -lKF6CoreAddons -lKF6Service -lKF6Solid -lKF6JobWidgets)

if [[ ${1:-} == "--tests" ]]; then
  # shellcheck disable=SC2046
  moc=/usr/lib/qt6/moc
  [[ -x $moc ]] || moc=$(command -v moc-qt6 || command -v moc)
  "$moc" "$here/src/tagsearch.h" -o "$out/moc_tests_tagsearch.cpp"
  "$moc" "$here/src/recents.h" -o "$out/moc_tests_recents.cpp"
  "$moc" "$here/src/filesearch.h" -o "$out/moc_tests_filesearch.cpp"
  "$moc" "$here/src/savedsearches.h" -o "$out/moc_tests_savedsearches.cpp"
  "$moc" "$here/src/archivejob.h" -o "$out/moc_tests_archivejob.cpp"
  "$moc" "$here/src/programlaunch.h" -o "$out/moc_tests_programlaunch.cpp"
  extra=()
  suffix=""
  if [[ ${2:-} == "--asan" ]]; then
    extra=(-g -fsanitize=address,undefined -fno-omit-frame-pointer)
    suffix="-asan"
  fi
  # tst_menushortcuts runs Qt.labs.platform menus offscreen (Qml, Widgets, Test) and includes globalmenu.h (DBus).
  g++ "${cxxflags[@]}" "${extra[@]}" -I"$here/src" -I"$root/apps" $(pkg-config --cflags Qt6Core Qt6Gui Qt6Quick Qt6Widgets Qt6Qml Qt6DBus Qt6Test) \
    "$root/tests/unit/files/tst_filelogic.cpp" "$root/tests/unit/files/tst_previewqueue.cpp" "$root/tests/unit/files/tst_tags.cpp" \
    "$root/tests/unit/files/tst_tagsearch.cpp" "$root/tests/unit/files/tst_folderstyle.cpp" "$root/tests/unit/files/tst_folderviews.cpp" "$root/tests/unit/files/tst_imagerotate.cpp" "$root/tests/unit/files/tst_imagesize.cpp" "$root/tests/unit/files/tst_recents.cpp" "$root/tests/unit/files/tst_folderprune.cpp" "$root/tests/unit/files/tst_search.cpp" "$root/tests/unit/files/tst_navlogic.cpp" "$root/tests/unit/files/tst_renamelogic.cpp" "$root/tests/unit/files/tst_archive.cpp" "$root/tests/unit/files/tst_batchops.cpp" "$root/tests/unit/files/tst_permissionlogic.cpp" \
    "$root/tests/unit/files/tst_appscope.cpp" "$root/tests/unit/files/tst_runmode.cpp" "$root/tests/unit/files/tst_applications.cpp" "$root/tests/unit/files/tst_autoappearance.cpp" "$root/tests/unit/files/tst_launchguard.cpp" "$root/tests/unit/files/tst_programlaunch.cpp" "$root/tests/unit/files/tst_appicons.cpp" "$root/tests/unit/files/tst_imageproviders.cpp" \
    "$root/tests/unit/files/tst_menushortcuts.cpp" "$root/tests/unit/files/tst_volumelogic.cpp" "$here/src/volumelogic.cpp" \
    "$here/src/filelogic.cpp" "$here/src/launchguard.cpp" "$here/src/programlaunch.cpp" "$out/moc_tests_programlaunch.cpp" "$here/src/taglogic.cpp" "$here/src/tagstore.cpp" "$here/src/tagsearch.cpp" "$here/src/applicationslogic.cpp" "$here/src/appicons.cpp" "$here/src/imageproviders.cpp" "$here/src/folderstylelogic.cpp" "$here/src/folderstylestore.cpp" "$here/src/folderviews.cpp" "$here/src/imagerotate.cpp" "$here/src/imagesize.cpp" "$here/src/recents.cpp" "$here/src/searchlogic.cpp" "$here/src/navlogic.cpp" "$here/src/renamelogic.cpp" "$here/src/archivelogic.cpp" "$here/src/batchops.cpp" "$here/src/archivejob.cpp" "$here/src/permissionlogic.cpp" "$here/src/filesearch.cpp" "$here/src/savedsearches.cpp" "$out/moc_tests_tagsearch.cpp" "$out/moc_tests_recents.cpp" "$out/moc_tests_filesearch.cpp" "$out/moc_tests_savedsearches.cpp" "$out/moc_tests_archivejob.cpp" \
    $(pkg-config --libs Qt6Core Qt6Gui Qt6Quick Qt6Widgets Qt6Qml Qt6DBus Qt6Test) -lgtest -lgtest_main -pthread \
    -o "$out/files-unit-tests$suffix"
  echo "built $out/files-unit-tests$suffix"
  # Grassfield's KIO dialogs (ADR-0035 D-12 a) and the panels' listings (FolderModel.chooser, D-4): the logic and real KIO
  # jobs and listings, against the Files library; its own main (a scratch home, offscreen). Not built in the sanitized run:
  # the KIO jobs and the scratch home are its subject, not memory safety.
  if [[ -z $suffix ]]; then
  "$0" --core >/dev/null
  # The programs tst_fileslaunch opens through FilesApp::open (tests/unit/files/launch_fixture.cpp): one that leaves a mark in
  # its working folder, one that stays a moment, one that fails as an AppImage without FUSE 2 does, one linked to a library
  # that is not on any search path (no rpath; the library sits in lib/, which the loader never reads).
  fixtures=$out/launch-fixtures
  fixture_src=$root/tests/unit/files/launch_fixture.cpp
  mkdir -p "$fixtures/lib"
  g++ -std=c++17 -O1 -fPIC -shared -DFIXTURE_LIBRARY "$fixture_src" -o "$fixtures/lib/libgflaunchmissing.so"
  g++ -std=c++17 -O1 -DFIXTURE_PROBE "$fixture_src" -o "$fixtures/probe"
  g++ -std=c++17 -O1 -DFIXTURE_STAY "$fixture_src" -o "$fixtures/stay"
  g++ -std=c++17 -O1 -DFIXTURE_FUSE "$fixture_src" -o "$fixtures/fuse"
  g++ -std=c++17 -O1 -DFIXTURE_NEEDS_LIBRARY "$fixture_src" -L"$fixtures/lib" -lgflaunchmissing -o "$fixtures/needs-library"
  # shellcheck disable=SC2046
  g++ "${cxxflags[@]}" "${kfdefs[@]}" "-DFILES_SOURCE_DIR=\"$here/src\"" "-DFILES_LAUNCH_FIXTURES=\"$fixtures\"" -I"$here/src" -I"$root/apps" "${kf_includes[@]}" \
    $(pkg-config --cflags Qt6Core Qt6Gui Qt6Widgets Qt6DBus Qt6Network Qt6Qml Qt6Quick) \
    "$root/tests/unit/files/tst_kioprompts.cpp" "$root/tests/unit/files/tst_kiodialogs.cpp" "$root/tests/unit/files/tst_folderchooser.cpp" \
    "$root/tests/unit/files/tst_diskprobe.cpp" "$root/tests/unit/files/tst_applicationchooser.cpp" "$root/tests/unit/files/tst_fileops.cpp" \
    "$root/tests/unit/files/tst_fileslaunch.cpp" \
    "$out/libgrassfield-files-core.a" \
    $(pkg-config --libs Qt6Core Qt6Gui Qt6Widgets Qt6DBus Qt6Network Qt6Qml Qt6Quick wayland-client) "${kf_libs[@]}" -lgtest -pthread -o "$out/files-kio-tests"
  echo "built $out/files-kio-tests"
  fi
  exit 0
fi

# The Files library (files-core.cmake, decision 4b-1 of ADR-0035): every source but main.cpp, compiled in parallel (KIO
# headers are heavy) into one archive that grassfield-files and grassfield-portal link.
moc=/usr/lib/qt6/moc
[[ -x $moc ]] || moc=$(command -v moc-qt6 || command -v moc)
read -r -a qt_cflags <<<"$(pkg-config --cflags Qt6Widgets Qt6Gui Qt6Qml Qt6Quick Qt6DBus Qt6Network wayland-client) -I/usr/include/qt6/QtGui/$(pkg-config --modversion Qt6Gui) -I/usr/include/qt6/QtGui/$(pkg-config --modversion Qt6Gui)/QtGui -I/usr/include/qt6/QtCore/$(pkg-config --modversion Qt6Gui)"
read -r -a qt_libs <<<"$(pkg-config --libs Qt6Widgets Qt6Gui Qt6Qml Qt6Quick Qt6DBus Qt6Network wayland-client)"
# Compiles each source into $objdir in parallel; the object paths go to the global `objs`.
compile() {
  local objdir=$1; shift
  mkdir -p "$objdir"
  local pids=() status=0 src obj pid
  objs=()
  for src in "$@"; do
    obj=$objdir/$(basename "${src%.cpp}").o
    objs+=("$obj")
    g++ "${cxxflags[@]}" "${kfdefs[@]}" "${defs[@]}" -I"$here/src" -I"$here/.." -I"$root/ui/i18n" -I"$out" "${kf_includes[@]}" "${qt_cflags[@]}" \
      -c "$src" -o "$obj" &
    pids+=($!)
  done
  for pid in "${pids[@]}"; do wait "$pid" || status=1; done
  [[ $status -eq 0 ]] || { echo "build-direct: compilation failed" >&2; exit 1; }
}

defs=()
mocs=()
for h in foldermodel placesmodel filesapp tagsearch filesearch savedsearches archivejob recents kioprompts applicationchooser diskprobe programlaunch; do
  "$moc" "${kf_includes[@]}" "$here/src/$h.h" -o "$out/moc_files_$h.cpp"
  mocs+=("$out/moc_files_$h.cpp")
done
# The apps' shared ongoing-activity client (ADR-0052).
"$moc" "$here/../ongoing.h" -o "$out/moc_files_ongoing.cpp"
mocs+=("$out/moc_files_ongoing.cpp")
compile "$out/files-core-obj" "$here/src/filesapp.cpp" "$here/src/foldermodel.cpp" "$here/src/placesmodel.cpp" "$here/src/diskprobe.cpp" "$here/src/volumelogic.cpp" \
  "$here/src/imageproviders.cpp" "$here/src/filelogic.cpp" "$here/src/launchguard.cpp" "$here/src/programlaunch.cpp" "$here/src/taglogic.cpp" "$here/src/tagstore.cpp" \
  "$here/src/tagsearch.cpp" "$here/src/searchlogic.cpp" "$here/src/navlogic.cpp" "$here/src/renamelogic.cpp" "$here/src/archivelogic.cpp" "$here/src/batchops.cpp" "$here/src/archivejob.cpp" "$here/src/permissionlogic.cpp" "$here/src/filesearch.cpp" "$here/src/savedsearches.cpp" "$here/src/applicationslogic.cpp" "$here/src/appicons.cpp" "$here/src/folderstylelogic.cpp" "$here/src/folderstylestore.cpp" "$here/src/folderviews.cpp" "$here/src/imagerotate.cpp" "$here/src/imagesize.cpp" "$here/src/recents.cpp" \
  "$here/src/kioprompts.cpp" "$here/src/kiopromptlogic.cpp" "$here/src/applicationchooser.cpp" "${mocs[@]}"
core=$out/libgrassfield-files-core.a
rm -f "$core"
ar rcs "$core" "${objs[@]}"
if [[ ${1:-} == "--core" ]]; then
  echo "built $core"
  exit 0
fi

# The app: its main() (the QML directory baked in) against the library.
if [[ ${1:-} != "--install-paths" ]]; then
  defs+=("-DGRASSFIELD_FILES_QML_DIR=\"$here/qml\"")
fi
compile "$out/files-obj" "$here/src/main.cpp"
g++ "${objs[@]}" "$core" "${qt_libs[@]}" "${kf_libs[@]}" -o "$out/grassfield-files"
echo "built $out/grassfield-files"
