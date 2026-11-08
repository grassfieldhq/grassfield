#!/usr/bin/env bash
# Builds the test fixtures with g++/gcc + pkg-config (no CMake, no moc):
#   .dev/build/menu-demo        tests/fixtures/menu-demo      (Qt6Widgets + Qt6DBus)
#   .dev/build/huge-menu        tests/fixtures/huge-menu      (Qt6DBus + Qt6Network; hostile huge GetLayout)
#   .dev/build/fake-registrar  tests/fixtures/fake-registrar (Qt6DBus)
#   .dev/build/appmenu-client   tests/fixtures/appmenu-client (C, wayland-client + wayland-scanner)
#   .dev/build/qt-theme-probe   tests/fixtures/qt-theme-probe (Qt6Widgets + Qt's private QtGui headers, ADR-0054)
# Usage: tests/fixtures/build.sh [qt-theme-probe|menu-demo|fake-registrar|appmenu-client|huge-menu|all]   (default all)
set -euo pipefail

root=$(git -C "$(dirname "$0")" rev-parse --show-toplevel)
out=$root/.dev/build
mkdir -p "$out"
what=${1:-all}
flags=(-std=c++17 -O1 -g -fPIC -Wall -Wextra)

if [[ $what == menu-demo || $what == all ]]; then
  # shellcheck disable=SC2046
  g++ "${flags[@]}" $(pkg-config --cflags Qt6Widgets Qt6DBus) "$root/tests/fixtures/menu-demo/main.cpp" \
    $(pkg-config --libs Qt6Widgets Qt6DBus) -o "$out/menu-demo"
  echo "built $out/menu-demo"
fi

if [[ $what == qt-theme-probe || $what == all ]]; then
  # The probe reads the platform theme (QPA, private headers of the Qt that is installed).
  qtv=$(pkg-config --modversion Qt6Gui)
  priv=(-I"/usr/include/qt6/QtGui/$qtv" -I"/usr/include/qt6/QtGui/$qtv/QtGui" -I"/usr/include/qt6/QtCore/$qtv" -I"/usr/include/qt6/QtCore/$qtv/QtCore")
  # shellcheck disable=SC2046
  g++ "${flags[@]}" -Wno-sfinae-incomplete "${priv[@]}" $(pkg-config --cflags Qt6Widgets) "$root/tests/fixtures/qt-theme-probe/main.cpp" \
    $(pkg-config --libs Qt6Widgets) -o "$out/qt-theme-probe"
  echo "built $out/qt-theme-probe"
fi

if [[ $what == appmenu-client || $what == all ]]; then
  gen=$out/appmenu-client-gen
  mkdir -p "$gen"
  wayland-scanner client-header "$root/compositor/protocols/appmenu.xml" "$gen/appmenu-client-protocol.h"
  wayland-scanner private-code "$root/compositor/protocols/appmenu.xml" "$gen/appmenu-protocol.c"
  # xdg-shell for the --spam mode (a real, mapped toplevel window).
  xdg_shell=$(pkg-config --variable=pkgdatadir wayland-protocols)/stable/xdg-shell/xdg-shell.xml
  wayland-scanner client-header "$xdg_shell" "$gen/xdg-shell-client-protocol.h"
  wayland-scanner private-code "$xdg_shell" "$gen/xdg-shell-protocol.c"
  # shellcheck disable=SC2046
  gcc -std=c11 -O1 -g -Wall -Wextra -I"$gen" "$root/tests/fixtures/appmenu-client/main.c" "$gen/appmenu-protocol.c" \
    "$gen/xdg-shell-protocol.c" $(pkg-config --cflags --libs wayland-client) -o "$out/appmenu-client"
  echo "built $out/appmenu-client"
fi

if [[ $what == huge-menu || $what == all ]]; then
  # shellcheck disable=SC2046
  g++ "${flags[@]}" $(pkg-config --cflags Qt6DBus Qt6Network) "$root/tests/fixtures/huge-menu/main.cpp" \
    $(pkg-config --libs Qt6DBus Qt6Network) -o "$out/huge-menu"
  echo "built $out/huge-menu"
fi

if [[ $what == fake-registrar || $what == all ]]; then
  # shellcheck disable=SC2046
  g++ "${flags[@]}" $(pkg-config --cflags Qt6DBus) "$root/tests/fixtures/fake-registrar/main.cpp" \
    $(pkg-config --libs Qt6DBus) -o "$out/fake-registrar"
  echo "built $out/fake-registrar"
fi
