#!/usr/bin/env bash
# Direct build of Grassfield Screenshot with g++ (see CMakeLists.txt; ADR-0066 D-3).
# Usage: apps/screenshot/build-direct.sh [--install-paths]   (.dev/build/grassfield-screenshot; --install-paths bakes /usr/share)
#        apps/screenshot/build-direct.sh --tests [--asan]     (.dev/build/screenshot-unit-tests, or -asan with
#                                                              -fsanitize=address,undefined)
# Set GF_JOBS (default 2) to limit the compiler processes that run at once.
set -euo pipefail
here=$(cd "$(dirname "$0")" && pwd)
root=$(git -C "$here" rev-parse --show-toplevel)
out=$root/.dev/build
mkdir -p "$out"

# GCC 16 warns inside Qt headers (-Wsfinae-incomplete); keep our own warnings visible.
cxxflags=(-std=c++17 -O2 -Wall -Wextra -Wno-sfinae-incomplete -fPIC "-DGRASSFIELD_VERSION=\"$(tr -d "[:space:]" <"$root/VERSION")\"")
suffix=""
if [[ " $* " == *" --asan "* ]]; then
  cxxflags+=(-g -fsanitize=address,undefined -fno-omit-frame-pointer)
  suffix="-asan"
fi
jobs=${GF_JOBS:-2}
core=(screenshotlogic layers atomicfile capturehistory document appearance screenshotapp)
moc=/usr/lib/qt6/moc
[[ -x $moc ]] || moc=$(command -v moc-qt6 || command -v moc)
for m in appearance screenshotapp; do
  "$moc" "$here/src/$m.h" -o "$out/moc_screenshot_$m$suffix.cpp"
done

# One object per source, at most $jobs compilers at a time (nice is the caller's).
objdir=$out/screenshot-obj$suffix
mkdir -p "$objdir"
# shellcheck disable=SC2046
compile() { # compile <source> <object> [extra flags...]
  local src=$1 obj=$2
  shift 2
  g++ "${cxxflags[@]}" "$@" -I"$here/src" -I"$here/.." -I"$root/ui/i18n" $(pkg-config --cflags Qt6Core Qt6Gui Qt6Qml Qt6Quick Qt6DBus) -c "$src" -o "$obj"
}
objects=()
pids=()
build_all() { # build_all <extra flags...>: every core source and its moc file
  local n
  for n in "${core[@]}"; do
    objects+=("$objdir/$n.o")
    compile "$here/src/$n.cpp" "$objdir/$n.o" "$@" &
    pids+=($!)
    while (($(jobs -r | wc -l) >= jobs)); do wait -n || true; done
  done
  for n in appearance screenshotapp; do
    objects+=("$objdir/moc_$n.o")
    compile "$out/moc_screenshot_$n$suffix.cpp" "$objdir/moc_$n.o" "$@" &
    pids+=($!)
    while (($(jobs -r | wc -l) >= jobs)); do wait -n || true; done
  done
  local rc=0 p
  for p in "${pids[@]}"; do wait "$p" || rc=1; done
  return $rc
}

case ${1:-} in
  --tests)
    build_all
    tests=()
    for t in "$root"/tests/unit/screenshot/tst_*.cpp; do
      tests+=("$t")
    done
    # shellcheck disable=SC2046
    g++ "${cxxflags[@]}" -I"$here/src" -I"$here/.." $(pkg-config --cflags Qt6Core Qt6Gui Qt6Qml Qt6Quick) \
      "${objects[@]}" "${tests[@]}" \
      $(pkg-config --libs Qt6Core Qt6Gui Qt6Qml Qt6Quick Qt6DBus) -lgtest -pthread -o "$out/screenshot-unit-tests$suffix"
    echo "built $out/screenshot-unit-tests$suffix"
    ;;
  "" | --install-paths)
    defs=()
    if [[ ${1:-} != "--install-paths" ]]; then
      defs+=("-DGRASSFIELD_SCREENSHOT_QML_DIR=\"$here/qml\"")
    fi
    build_all
    qtver=$(pkg-config --modversion Qt6Gui)
    # windowchrome.h (ADR-0015) needs one Qt private header and libwayland-client.
    # shellcheck disable=SC2046
    g++ "${cxxflags[@]}" "${defs[@]}" -I"$here/src" -I"$here/.." -I"$root/ui/i18n" \
      $(pkg-config --cflags Qt6Gui Qt6Qml Qt6Quick Qt6DBus wayland-client) \
      -I"/usr/include/qt6/QtGui/$qtver" -I"/usr/include/qt6/QtGui/$qtver/QtGui" -I"/usr/include/qt6/QtCore/$qtver" \
      "${objects[@]}" "$here/src/main.cpp" \
      $(pkg-config --libs Qt6Gui Qt6Qml Qt6Quick Qt6DBus) -lwayland-client -pthread -o "$out/grassfield-screenshot"
    echo "built $out/grassfield-screenshot"
    # A dev session (scripts/dev/devenv.sh puts .dev/share first in XDG_DATA_DIRS) finds the entry and the icon here, so the
    # menu bar and Apps name it and Apps starts this build. Only under .dev/share, never in the owner's data directories.
    if [[ ${1:-} != "--install-paths" ]]; then
      share=$root/.dev/share
      mkdir -p "$share/applications" "$share/icons/hicolor/scalable/apps"
      sed "s|^Exec=grassfield-screenshot %f$|Exec=$out/grassfield-screenshot %f|" "$here/org.grassfield.Screenshot.desktop" \
        >"$share/applications/org.grassfield.Screenshot.desktop"
      cp "$root/branding/icons/apps/org.grassfield.Screenshot.svg" "$share/icons/hicolor/scalable/apps/"
    fi
    ;;
  *)
    echo "usage: apps/screenshot/build-direct.sh [--install-paths] | --tests [--asan]" >&2
    exit 2
    ;;
esac
