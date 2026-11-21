#!/usr/bin/env bash
# The real wallpaper offscreen: a change during a crossfade retargets it without a jump, a change back turns it back, the phase
# fade moves in steps (audit, wallpaper fade): tests/shell/wallpaper_retarget.d/harness.qml on a staged shell whose desktop module
# has a PanelWindow stand-in (tests/shell/panel_stub.d). Prints PASS or FAIL; exits non-zero on failure.
exec "$(dirname "$0")/panel_stub.d/run.sh" wallpaper_retarget desktop
