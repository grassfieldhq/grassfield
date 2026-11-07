#!/usr/bin/env bash
# A window that activates itself through xdg-activation-v1 on SIGUSR1 and unmaps itself (alive) on SIGUSR2, for the NESTED dev
# compositor only (tests/tools/xdgact).
# Usage (through the isolation helper, like every test client): scripts/dev/isolated.sh tests/tools/xdgact/xdgact.sh APP_ID [MIN_WIDTH | WxH]
# XDGACT_DECORATION=client|none|unbound changes what it negotiates (default: server_side; tests/compositor/decorations.sh).
# Builds the tool into .dev/tools/ on first use. Refuses anything but this tree's verified nested socket
# (dev_nested_target: live recorded compositor running this tree's dev config; never the owner's instance or WAYLAND_DISPLAY).
# Build only: tests/tools/xdgact/xdgact.sh --build
set -euo pipefail

root=$(git -C "$(dirname "$0")" rev-parse --show-toplevel)
dev=$root/.dev
src=$root/tests/tools/xdgact
bin=$dev/tools/xdgact
protocols=$(pkg-config --variable=pkgdatadir wayland-protocols)

if [[ ! -x $bin || $src/xdgact.c -nt $bin ]]; then
  mkdir -p "$dev/tools"
  wayland-scanner client-header "$protocols/stable/xdg-shell/xdg-shell.xml" "$dev/tools/xdg-shell-client-protocol.h"
  wayland-scanner private-code "$protocols/stable/xdg-shell/xdg-shell.xml" "$dev/tools/xdg-shell-protocol.c"
  wayland-scanner client-header "$protocols/staging/xdg-activation/xdg-activation-v1.xml" "$dev/tools/xdg-activation-v1-client-protocol.h"
  wayland-scanner private-code "$protocols/staging/xdg-activation/xdg-activation-v1.xml" "$dev/tools/xdg-activation-v1-protocol.c"
  wayland-scanner client-header "$protocols/unstable/xdg-decoration/xdg-decoration-unstable-v1.xml" "$dev/tools/xdg-decoration-unstable-v1-client-protocol.h"
  wayland-scanner private-code "$protocols/unstable/xdg-decoration/xdg-decoration-unstable-v1.xml" "$dev/tools/xdg-decoration-unstable-v1-protocol.c"
  # shellcheck disable=SC2046
  gcc -std=gnu11 -O1 -Wall -Wextra -I"$dev/tools" "$src/xdgact.c" "$dev/tools/xdg-shell-protocol.c" "$dev/tools/xdg-activation-v1-protocol.c" \
    "$dev/tools/xdg-decoration-unstable-v1-protocol.c" $(pkg-config --cflags --libs wayland-client) -o "$bin"
fi
[[ ${1:-} == --build ]] && exit 0

# shellcheck source=../../../scripts/dev/pidfile.sh
. "$root/scripts/dev/pidfile.sh"
dev_nested_target "$dev" || exit 1
WAYLAND_DISPLAY=$DEV_NESTED_SOCK exec "$bin" "$@"
