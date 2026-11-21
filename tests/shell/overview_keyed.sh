#!/usr/bin/env bash
# The real Overview offscreen (audit A-06, A-11): window items keyed by address, layers of one size through the zoom:
# tests/shell/overview_keyed.d/harness.qml on a staged shell whose overview module has a PanelWindow stand-in and reads the
# active workspace's windows from the harness (TestWins) instead of the compositor. Prints PASS or FAIL; exits non-zero on failure.
export STAGE_SED='s/Compositor\.windowsOn\(screenName, Compositor\.topologyRevision\)/TestWins.list/'
exec "$(dirname "$0")/panel_stub.d/run.sh" overview_keyed overview
