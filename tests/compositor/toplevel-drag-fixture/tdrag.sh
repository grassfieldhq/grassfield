#!/usr/bin/env bash
# tdrag: a Chromium stand-in for xdg_toplevel_drag_v1 (tests/compositor/toplevel-drag-fixture/tdrag.c), for the NESTED dev
# compositor only.
# Usage (through the isolation helper, like every test client): scripts/dev/isolated.sh tests/compositor/toplevel-drag-fixture/tdrag.sh MODE
# Builds the tool into .dev/tools/ on first use. Refuses anything but this tree's verified nested socket (dev_nested_target:
# live recorded compositor running this tree's dev config; never the owner's instance or WAYLAND_DISPLAY).
# Build only: tests/compositor/toplevel-drag-fixture/tdrag.sh --build
set -euo pipefail

root=$(git -C "$(dirname "$0")" rev-parse --show-toplevel)
dev=$root/.dev
src=$root/tests/compositor/toplevel-drag-fixture
bin=$dev/tools/tdrag
protocols=$(pkg-config --variable=pkgdatadir wayland-protocols)
drag_xml=$protocols/staging/xdg-toplevel-drag/xdg-toplevel-drag-v1.xml

if [[ ! -x $bin || $src/tdrag.c -nt $bin ]]; then
  [[ -f $drag_xml ]] || { echo "tdrag: $drag_xml not found (wayland-protocols)" >&2; exit 2; }
  mkdir -p "$dev/tools"
  wayland-scanner client-header "$protocols/stable/xdg-shell/xdg-shell.xml" "$dev/tools/xdg-shell-client-protocol.h"
  wayland-scanner private-code "$protocols/stable/xdg-shell/xdg-shell.xml" "$dev/tools/xdg-shell-protocol.c"
  wayland-scanner client-header "$drag_xml" "$dev/tools/xdg-toplevel-drag-v1-client-protocol.h"
  wayland-scanner private-code "$drag_xml" "$dev/tools/xdg-toplevel-drag-v1-protocol.c"
  # shellcheck disable=SC2046
  gcc -std=gnu11 -O1 -Wall -Wextra -I"$dev/tools" "$src/tdrag.c" "$dev/tools/xdg-shell-protocol.c" "$dev/tools/xdg-toplevel-drag-v1-protocol.c" \
    $(pkg-config --cflags --libs wayland-client) -o "$bin"
fi
[[ ${1:-} == --build ]] && exit 0

# shellcheck source=../../../scripts/dev/pidfile.sh
. "$root/scripts/dev/pidfile.sh"
dev_nested_target "$dev" || exit 1
WAYLAND_DISPLAY=$DEV_NESTED_SOCK exec "$bin" "$@"
