#!/usr/bin/env bash
# Grassfield Screenshot's packaging (slice B1, ADR-0066 D-3): grassfield-desktop's PKGBUILD builds and installs apps/screenshot,
# the CMake install lists the binary, the desktop entry, the icon and the QML, and the entry is a valid one that never claims a file
# type (the editor is started by the capture thumbnail and the launcher; "Open with" for every PNG stays Preview's).
# The first checks are static. With GF_SCREENSHOT_CMAKE_INSTALL=1 the script also configures, builds (2 jobs, nice) and installs
# the target into a scratch DESTDIR under the test scratch folder and lists what was installed: the step the integrator and
# `just check-cmake-build` run, kept off the default run because it compiles the app a second time (minutes).
set -uo pipefail

root=$(git -C "$(dirname "$0")" rev-parse --show-toplevel)
fails=0
check() { if [[ $2 == 0 ]]; then echo "PASS $1"; else echo "FAIL $1"; fails=1; fi; }
pkg=$root/packaging/arch/PKGBUILD
desktop=$root/apps/screenshot/org.grassfield.Screenshot.desktop

grep -q 'cmake -S "$(_root)/apps/screenshot" -B "$srcdir/screenshot-build" -G Ninja' "$pkg"
check "the PKGBUILD configures apps/screenshot" $?
grep -q 'cmake --build "$srcdir/screenshot-build"' "$pkg"
check "the PKGBUILD builds it" $?
grep -q 'DESTDIR="$pkgdir" cmake --install "$srcdir/screenshot-build"' "$pkg"
check "the PKGBUILD installs it into grassfield-desktop" $?
# The install happens in the grassfield-desktop package function (the one that installs Preview too).
awk '/^package_grassfield-desktop\(\)/ {f=1} f && /screenshot-build/ {found=1} /^package_grassfield-[a-z-]+\(\)/ && !/desktop/ {f=0} END {exit !found}' "$pkg"
check "that install is in package_grassfield-desktop" $?

cm=$root/apps/screenshot/CMakeLists.txt
grep -q 'install(TARGETS grassfield-screenshot RUNTIME DESTINATION bin)' "$cm"
check "CMake installs the binary to bin" $?
grep -q 'install(FILES org.grassfield.Screenshot.desktop DESTINATION share/applications)' "$cm"
check "CMake installs the desktop entry" $?
grep -q 'org.grassfield.Screenshot.svg' "$cm" && [[ -f $root/branding/icons/apps/org.grassfield.Screenshot.svg ]]
check "CMake installs the icon, which exists" $?
grep -q 'share/grassfield/screenshot/qml' "$cm"
check "CMake installs the QML" $?

[[ -f $desktop ]] && grep -q '^Exec=grassfield-screenshot %f$' "$desktop" && grep -q '^Icon=org.grassfield.Screenshot$' "$desktop" \
  && grep -q '^StartupWMClass=org.grassfield.Screenshot$' "$desktop"
check "the entry starts the binary with one file, names the icon and the app id" $?
if grep -q '^MimeType=' "$desktop"; then check "the entry claims no file type" 1; else check "the entry claims no file type" 0; fi
grep -q '^Name\[fr\]=' "$desktop"
check "the entry has a French name" $?
if command -v desktop-file-validate >/dev/null; then
  desktop-file-validate "$desktop"
  check "desktop-file-validate accepts the entry" $?
fi

if [[ ${GF_SCREENSHOT_CMAKE_INSTALL:-} == 1 ]]; then
  scratch=${GRASSFIELD_TEST_TMP:-${TMPDIR:-/tmp}}/gf-screenshot-package
  rm -rf "$scratch"
  mkdir -p "$scratch"
  log=$scratch/build.log
  if nice cmake -S "$root/apps/screenshot" -B "$scratch/build" -G Ninja -DCMAKE_BUILD_TYPE=Release -DCMAKE_INSTALL_PREFIX=/usr >"$log" 2>&1 \
    && nice cmake --build "$scratch/build" -j 2 >>"$log" 2>&1 \
    && DESTDIR="$scratch/pkg" cmake --install "$scratch/build" >>"$log" 2>&1; then
    check "CMake configures, builds at -j2 and installs" 0
  else
    tail -n 15 "$log"
    check "CMake configures, builds at -j2 and installs" 1
  fi
  for f in usr/bin/grassfield-screenshot usr/share/applications/org.grassfield.Screenshot.desktop \
    usr/share/icons/hicolor/scalable/apps/org.grassfield.Screenshot.svg usr/share/grassfield/screenshot/qml/Editor.qml \
    usr/share/grassfield/screenshot/qml/ZoomView.qml usr/share/grassfield/screenshot/qml/icons/fit.svg; do
    [[ -e $scratch/pkg/$f ]]
    check "the install lists /$f" $?
  done
  [[ -x $scratch/pkg/usr/bin/grassfield-screenshot ]]
  check "the binary is executable" $?
  rm -rf "$scratch"
fi
exit $fails
