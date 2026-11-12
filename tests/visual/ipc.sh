#!/usr/bin/env bash
# Quickshell IPC against the NESTED grassfield-shell only: ipc.sh <target> <function> [args...]
# e.g. tests/visual/ipc.sh menubar open controlcenter GF-REF
# The instance is selected by its PID, never by path: the shell's (.dev/shell.pid, written by scripts/dev/shell-run.sh), or,
# for the targets of the security process (lock, idle, security: ADR-0041 step 1, S2; polkit, secrets: S3; safemode: S4), that process's
# (.dev/security.pid, written by shell-run.sh too).
# Refuses the owner's Wayland socket and Hyprland instance (same guards as scripts/dev/pointer.sh).
set -euo pipefail

here=$(cd "$(dirname "$0")" && pwd)
root=$(cd "$here/../.." && pwd)
dev=$root/.dev
# shellcheck source=../../scripts/dev/pidfile.sh
. "$root/scripts/dev/pidfile.sh"
# Only this tree's live nested compositor and shell (records verified by start time).
dev_nested_target "$dev" || exit 1
sock=$DEV_NESTED_SOCK sig=$DEV_NESTED_SIG
[[ $# -ge 2 ]] || { echo "usage: ipc.sh <target> <function> [args...]" >&2; exit 2; }
case $1 in
  lock | idle | security | polkit | secrets | safemode)
    pid=$(dev_live_pid "$dev/security.pid") || { echo "ipc: no running nested security process (.dev/security.pid)" >&2; exit 1; }
    ;;
  *)
    pid=$(dev_live_pid "$dev/shell.pid") || { echo "ipc: no running nested shell (.dev/shell.pid)" >&2; exit 1; }
    ;;
esac

WAYLAND_DISPLAY=$sock HYPRLAND_INSTANCE_SIGNATURE=$sig exec qs ipc --pid "$pid" call "$@"
