#!/usr/bin/env bash
# The real Dock offscreen, magnified (audit, Dock fluidity): tests/shell/dock_transform.d/harness.qml on a staged shell whose dock
# module has a PanelWindow stand-in (tests/shell/panel_stub.d). Prints PASS or FAIL; exits non-zero on failure.
exec "$(dirname "$0")/panel_stub.d/run.sh" dock_transform dock
