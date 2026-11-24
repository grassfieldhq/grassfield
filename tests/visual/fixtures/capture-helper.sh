#!/usr/bin/env bash
# The capture helper for the NESTED session (GRASSFIELD_CAPTURE_HELPER, ADR-0019): packaging/bin/grassfield-capture of this tree, run so
# that its private folder ($XDG_RUNTIME_DIR/grassfield: state, ack, result, frozen frames) IS the dev shell's state folder
# (GRASSFIELD_STATE_HOME, where a dev shell reads them). The helper only accepts a real 0700 folder at that path, so the dev state
# folder is bind-mounted there, in a mount namespace of this one process (bwrap): the owner's live session never sees it and the
# helper never touches the owner's own capture state. Used by tests/visual/capture-suite.sh, and as the helper the toolbar runs.
set -euo pipefail
here=$(cd "$(dirname "$0")" && pwd)
root=$(cd "$here/../../.." && pwd)
state=${GRASSFIELD_STATE_HOME:?GRASSFIELD_STATE_HOME is not set}
runtime=${XDG_RUNTIME_DIR:?XDG_RUNTIME_DIR is not set}
case $(realpath -- "$state") in "$root"/.dev/*) ;; *) echo "capture-helper: $state is not under $root/.dev" >&2; exit 2 ;; esac
[[ -n ${WAYLAND_DISPLAY:-} && -n ${HYPRLAND_INSTANCE_SIGNATURE:-} ]] || { echo "capture-helper: not a nested environment" >&2; exit 2; }
# Never the owner's compositor: the instance must be this tree's nested one.
[[ $HYPRLAND_INSTANCE_SIGNATURE == "$(cat "$root/.dev/nested.instance")" ]] || { echo "capture-helper: not this tree's nested instance" >&2; exit 2; }
exec bwrap --dev-bind / / --bind "$state" "$runtime/grassfield" "$root/packaging/bin/grassfield-capture" "$@"
