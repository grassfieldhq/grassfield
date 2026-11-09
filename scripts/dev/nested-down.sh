#!/usr/bin/env bash
# Stop the nested shell, security process, menu bridge, private bus and compositor started by nested-up.sh / shell-run.sh and
# remove their records. Only processes whose record still matches are signalled (scripts/dev/pidfile.sh), never the
# owner's compositor, its group or session.
set -uo pipefail

root=$(git -C "$(dirname "$0")" rev-parse --show-toplevel)
dev=$root/.dev
main=$(cat "$dev/main.instance" 2>/dev/null || true)
# shellcheck source=pidfile.sh
. "$root/scripts/dev/pidfile.sh"

# Inside a PID namespace (the Claude Code sandbox) the session's processes are invisible or named by other PIDs:
# refuse, records kept.
dev_require_host nested-down

# The nested compositor must be this tree's: started with its dev config, and not the owner's instance.
nested=$(dev_live_pid "$dev/nested.pid" || true)
if [[ -n $nested ]]; then
  cmdline=$(tr '\0' ' ' <"/proc/$nested/cmdline" 2>/dev/null)
  owner_pids=$(hyprctl instances -j 2>/dev/null | jq -r --arg m "$main" --arg e "${HYPRLAND_INSTANCE_SIGNATURE:-}" \
    '.[] | select(.instance == $m or .instance == $e) | .pid')
  if [[ $cmdline != *"--config $root/config/hypr/dev.lua"* ]] || grep -qx "$nested" <<<"$owner_pids"; then
    echo "nested-down: refusing: recorded PID $nested is not this tree's nested Hyprland ($cmdline)" >&2
    exit 1
  fi
fi

status=0
dev_stop "$dev/shell.pid" grassfield-shell || status=1
# The security process (ADR-0041 S2) after the UI: it holds the nested session lock, if any (the compositor goes next).
dev_stop "$dev/security.pid" grassfield-security || status=1
# The menu bridge releases com.canonical.AppMenu.Registrar on SIGTERM, then the private bus goes (shell-run.sh).
dev_stop "$dev/menu-bridge.pid" grassfield-menu-bridge || status=1
dev_stop "$dev/bus.pid" "private D-Bus bus" || status=1
rm -f "$dev/bus.address" "$dev/run/menu-bridge.sock" "$dev/security.sig"
if [[ -n $nested ]]; then
  dev_stop "$dev/nested.pid" "nested Hyprland" "$nested" || status=1
else
  dev_stop "$dev/nested.pid" "nested Hyprland" || status=1
fi
rm -f "$dev/nested.instance" "$dev/nested.wayland"
exit "$status"
