#!/usr/bin/env bash
# Rewrites the golden exports of the Screenshot editor (tests/unit/screenshot/golden/*.png) from the current exporter.
# Run it only after a deliberate change of how shapes are drawn, then look at the PNGs (and `git diff --stat`) before committing:
# a golden that is regenerated without a look proves nothing. See golden/README.md for the tolerance and the determinism rules.
# Usage: tests/unit/screenshot/regenerate-goldens.sh [--rebuild]   (an existing .dev/build test binary is reused)
set -euo pipefail
root=$(git -C "$(dirname "$0")" rev-parse --show-toplevel)
bin=$root/.dev/build/screenshot-unit-tests
if [[ ! -x $bin || ${1:-} == "--rebuild" ]]; then
  nice "$root/apps/screenshot/build-direct.sh" --tests
fi
# Offscreen and no platform theme: no font, theme or style reaches the drawing.
env -u QT_QPA_PLATFORMTHEME QT_QPA_PLATFORM=offscreen GF_UPDATE_GOLDENS=1 "$bin" --gtest_filter='Tools/GoldenTest.*' --gtest_brief=1
echo "goldens written to $root/tests/unit/screenshot/golden"
