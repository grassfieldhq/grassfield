#!/usr/bin/env bash
# The CMake definitions of the apps, configured the way packaging/arch/PKGBUILD configures them (Ninja, Release,
# prefix /usr), into scratch directories under .dev/cmake-check/. Nothing is installed.
#
#   scripts/dev/check-cmake.sh            configure only (seconds): catches a missing find_package component, such as the
#                                         private Qt module that Qt 6.11 loads only when asked (Qt6::GuiPrivate)
#   scripts/dev/check-cmake.sh --build    configure and build every target (minutes)
#
# The build-direct.sh scripts do not read CMakeLists.txt, so without this a broken CMake definition would only show in
# makepkg.
set -euo pipefail
root=$(git -C "$(dirname "$0")" rev-parse --show-toplevel)
out=$root/.dev/cmake-check
build=0
[[ ${1:-} == --build ]] && build=1
mkdir -p "$out"
fail=0
for project in apps/settings apps/wallpaper-tool apps/files apps/preview apps/clipboard-helper apps/store apps/secrets-handover apps/portal-settings apps/portal apps/activity apps/memos bridges/menu-bridge bridges/prompter packaging/qt-platform-theme ui/i18n; do
  dir=$out/$(basename "$project")
  log=$out/$(basename "$project").log
  if cmake -S "$root/$project" -B "$dir" -G Ninja -DCMAKE_BUILD_TYPE=Release -DCMAKE_INSTALL_PREFIX=/usr >"$log" 2>&1 \
    && { [[ $build == 0 ]] || cmake --build "$dir" >>"$log" 2>&1; }; then
    echo "ok:   $project ($([[ $build == 1 ]] && echo built || echo configured))"
  else
    echo "FAIL: $project (see $log)"
    tail -n 12 "$log"
    fail=1
  fi
done
exit $fail
