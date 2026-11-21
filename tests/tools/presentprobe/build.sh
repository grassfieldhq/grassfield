#!/usr/bin/env bash
# Builds tests/tools/presentprobe (the presentation-time probe of gate P3) into OUTDIR (default: this tree's .dev/tools).
#   tests/tools/presentprobe/build.sh [OUTDIR]       prints the binary's path; rebuilds only when a source is newer
# Needs wayland-scanner, wayland-protocols (presentation-time, xdg-shell), libwayland-client and a C compiler (cc). The
# wlr-layer-shell protocol file is in this directory (wlroots, Drew DeVault's notice in the file). Test tooling, not packaged.
set -euo pipefail
src=$(cd "$(dirname "$0")" && pwd)
out=${1:-$(git -C "$src" rev-parse --show-toplevel)/.dev/tools}
bin=$out/presentprobe
gen=$out/presentprobe-gen
protocols=$(pkg-config --variable=pkgdatadir wayland-protocols) || { echo "presentprobe: wayland-protocols not found (pkg-config)" >&2; exit 2; }
command -v wayland-scanner >/dev/null || { echo "presentprobe: wayland-scanner not found" >&2; exit 2; }
if [[ -x $bin && $bin -nt $src/presentprobe.c && $bin -nt $src/wlr-layer-shell-unstable-v1.xml && $bin -nt $src/build.sh ]]; then
  echo "$bin"
  exit 0
fi
mkdir -p "$gen"
xmls=("$protocols/stable/presentation-time/presentation-time.xml" "$protocols/stable/xdg-shell/xdg-shell.xml" "$src/wlr-layer-shell-unstable-v1.xml")
code=()
for xml in "${xmls[@]}"; do
  name=$(basename "$xml" .xml)
  wayland-scanner client-header "$xml" "$gen/$name-client-protocol.h"
  wayland-scanner private-code "$xml" "$gen/$name-protocol.c"
  code+=("$gen/$name-protocol.c")
done
# shellcheck disable=SC2046
${CC:-cc} -std=gnu11 -O2 -Wall -Wextra -Werror -I"$gen" "$src/presentprobe.c" "${code[@]}" $(pkg-config --cflags --libs wayland-client) -o "$bin.tmp"
mv "$bin.tmp" "$bin"
echo "$bin"
