#!/usr/bin/env bash
# Direct build of the activity monitor with g++ (see CMakeLists.txt; ADR-0038).
# Usage: apps/activity/build-direct.sh [--install-paths]   (.dev/build/grassfield-activity; --install-paths bakes /usr/share)
#        apps/activity/build-direct.sh --tests [--asan]     (.dev/build/activity-unit-tests, activity-window-tests and,
#                                                            unsanitized, activity-window-qml-tests; or -asan with
#                                                            -fsanitize=address,undefined)
#        apps/activity/build-direct.sh --bench [--asan]     (.dev/build/activity-sampler-bench)
set -euo pipefail
here=$(cd "$(dirname "$0")" && pwd)
root=$(git -C "$here" rev-parse --show-toplevel)
out=$root/.dev/build
mkdir -p "$out"

cxxflags=(-std=c++17 -O2 -Wall -Wextra -fPIC)
suffix=""
if [[ " $* " == *" --asan "* ]]; then
  cxxflags+=(-g -fsanitize=address,undefined -fno-omit-frame-pointer)
  suffix="-asan"
fi
# The sampler, the signal path and Inspect's reader: plain C++17 and POSIX, no Qt (steps 1, 2c and 2d).
sampler=("$here"/src/inspect.cpp "$here"/src/machine.cpp "$here"/src/netdiag.cpp "$here"/src/procparse.cpp "$here"/src/sampler.cpp "$here"/src/signals.cpp
  "$here"/src/textclean.cpp "$here"/src/units.cpp)
# The window's backend (step 2): Qt Core, Gui and DBus. GCC 16 warns inside Qt headers (-Wsfinae-incomplete).
window=("$here"/src/actions.cpp "$here"/src/activityapp.cpp "$here"/src/apphistory.cpp "$here"/src/activitystate.cpp "$here"/src/battery.cpp "$here"/src/columns.cpp
  "$here"/src/desktopapps.cpp "$here"/src/efficiency.cpp "$here"/src/format.cpp "$here"/src/graphgeometry.cpp "$here"/src/inhibitors.cpp "$here"/src/inspection.cpp
  "$here"/src/performance.cpp "$here"/src/processtable.cpp "$here"/src/runtimefiles.cpp "$here"/src/samplerworker.cpp "$here"/src/summary.cpp)
mocked=(actions activityapp apphistory battery efficiency inhibitors inspection performance processtable runtimefiles samplerworker summary)
qtflags=(-Wno-sfinae-incomplete "-DGRASSFIELD_VERSION=\"$(tr -d "[:space:]" <"$root/VERSION")\"" -I"$here/src" -I"$here/.." -I"$root/ui/i18n")
moc=/usr/lib/qt6/moc
[[ -x $moc ]] || moc=$(command -v moc-qt6 || command -v moc)
generated=()
run_moc() {
  local m
  for m in "${mocked[@]}"; do
    "$moc" "$here/src/$m.h" -o "$out/moc_activity_$m$suffix.cpp"
    generated+=("$out/moc_activity_$m$suffix.cpp")
  done
}
# The graph's QQuickItem (graphitem.h): in the app and its QML tests only (Qt Quick).
moc_graphitem() {
  "$moc" "$here/src/graphitem.h" -o "$out/moc_activity_graphitem.cpp"
}

case ${1:-} in
  --tests)
    g++ "${cxxflags[@]}" -I"$here/src" "${sampler[@]}" "$root"/tests/unit/activity/tst_*.cpp \
      -lgtest -lgtest_main -pthread -o "$out/activity-unit-tests$suffix"
    echo "built $out/activity-unit-tests$suffix"
    run_moc
    # The window's tests have their own main (tst_main.cpp: a QCoreApplication around the cases).
    # shellcheck disable=SC2046
    g++ "${cxxflags[@]}" "${qtflags[@]}" $(pkg-config --cflags Qt6Core Qt6Gui Qt6DBus Qt6Test) \
      "${sampler[@]}" "${window[@]}" "${generated[@]}" "$root"/tests/unit/activity/window/tst_*.cpp \
      $(pkg-config --libs Qt6Core Qt6Gui Qt6DBus Qt6Test) -lgtest -pthread -o "$out/activity-window-tests$suffix"
    echo "built $out/activity-window-tests$suffix"
    # A-W1: the window with its real backend on a fixture tree, offscreen (its own main). Not built sanitized: the QML
    # engine's own code is not what it tests. One Qt private header: the window's exposure, as a compositor's suspended
    # state sets it.
    if [[ -z $suffix ]]; then
      moc_graphitem
      qtver=$(pkg-config --modversion Qt6Gui)
      # shellcheck disable=SC2046
      g++ "${cxxflags[@]}" "${qtflags[@]}" "-DACTIVITY_ROOT=\"$root\"" $(pkg-config --cflags Qt6Gui Qt6Qml Qt6Quick Qt6DBus Qt6Test) \
        -I"/usr/include/qt6/QtGui/$qtver" -I"/usr/include/qt6/QtGui/$qtver/QtGui" -I"/usr/include/qt6/QtCore/$qtver" \
        -I"/usr/include/qt6/QtCore/$qtver/QtCore" \
        "${sampler[@]}" "${window[@]}" "${generated[@]}" "$root"/tests/unit/activity/qml/tst_window.cpp \
        "$root"/tests/unit/activity/qml/tst_keywindow.cpp "$root"/tests/unit/activity/qml/tst_graph.cpp "$here/src/graphitem.cpp" \
        "$out/moc_activity_graphitem.cpp" \
        $(pkg-config --libs Qt6Gui Qt6Qml Qt6Quick Qt6DBus Qt6Test) -lgtest -pthread -o "$out/activity-window-qml-tests"
      echo "built $out/activity-window-qml-tests"
    fi
    ;;
  --bench)
    g++ "${cxxflags[@]}" -I"$here/src" "${sampler[@]}" "$here/src/bench.cpp" -pthread -o "$out/activity-sampler-bench$suffix"
    echo "built $out/activity-sampler-bench$suffix"
    ;;
  "" | --install-paths)
    defs=()
    if [[ ${1:-} != "--install-paths" ]]; then
      defs+=("-DGRASSFIELD_ACTIVITY_QML_DIR=\"$here/qml\"")
    fi
    run_moc
    moc_graphitem
    qtver=$(pkg-config --modversion Qt6Gui)
    # windowchrome.h (ADR-0015) needs one Qt private header and libwayland-client.
    # shellcheck disable=SC2046
    g++ "${cxxflags[@]}" "${qtflags[@]}" "${defs[@]}" \
      $(pkg-config --cflags Qt6Gui Qt6Qml Qt6Quick Qt6DBus wayland-client) \
      -I"/usr/include/qt6/QtGui/$qtver" -I"/usr/include/qt6/QtGui/$qtver/QtGui" -I"/usr/include/qt6/QtCore/$qtver" \
      "${sampler[@]}" "${window[@]}" "${generated[@]}" "$here/src/main.cpp" "$here/src/graphitem.cpp" "$out/moc_activity_graphitem.cpp" \
      $(pkg-config --libs Qt6Gui Qt6Qml Qt6Quick Qt6DBus) -lwayland-client -pthread -o "$out/grassfield-activity"
    echo "built $out/grassfield-activity"
    # A dev session (scripts/dev/devenv.sh puts .dev/share first in XDG_DATA_DIRS) finds the entry and the icon here, so the
    # menu bar and Apps name it and Apps starts this build. Only under .dev/share, never in the owner's data directories.
    if [[ ${1:-} != "--install-paths" ]]; then
      share=$root/.dev/share
      mkdir -p "$share/applications" "$share/icons/hicolor/scalable/apps"
      sed "s|^Exec=grassfield-activity$|Exec=$out/grassfield-activity|" "$here/org.grassfield.Activity.desktop" \
        >"$share/applications/org.grassfield.Activity.desktop"
      cp "$root/branding/icons/apps/org.grassfield.Activity.svg" "$share/icons/hicolor/scalable/apps/"
    fi
    ;;
  *)
    echo "usage: apps/activity/build-direct.sh [--install-paths] | --tests [--asan] | --bench [--asan]" >&2
    exit 2
    ;;
esac
