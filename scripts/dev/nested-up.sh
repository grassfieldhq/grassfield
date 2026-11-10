#!/usr/bin/env bash
# Start the nested Grassfield dev compositor (master-prompt Appendix C2, §7.1 L1).
# All state lives in .dev/. The owner's main instance is recorded so scripts/nestctl can refuse it.
set -euo pipefail

root=$(git -C "$(dirname "$0")" rev-parse --show-toplevel)

# Options (preferred over env prefixes: a bare `scripts/dev/nested-up.sh …` command matches the
# Claude Code sandbox exclusion, an `VAR=… scripts/dev/nested-up.sh` prefix may not).
while [[ $# -gt 0 ]]; do
  case $1 in
    --private-bus) export GRASSFIELD_PRIVATE_BUS=1 ;;  # the default; kept for scripts that spell it out
    --session-bus) export GRASSFIELD_PRIVATE_BUS=0 ;;  # the owner's session bus (rare tests only)
    --no-plugin) export GRASSFIELD_NO_PLUGIN=1 ;;
    --visual-fixtures) export GRASSFIELD_VISUAL_FIXTURES=1 ;;  # test hooks and fixed values (shell/services/VisualFixtures.qml, dev only)
    --migrated) export GRASSFIELD_MIGRATED=1 ;;  # the packaged form of the UI tree (ADR-0056): shell-run.sh --migrated; the bindings address .dev/migrated/shell
    --render-timing) export GRASSFIELD_RENDER_TIMING=1 ;;  # Qt scene graph frame timing in .dev/shell.log (QSG_RENDER_TIMING)
    --unit-env) export GRASSFIELD_UNIT_ENV=1 ;;  # shell with grassfield-shell.service's own variables (shell-run.sh --unit-env)
    --lang) export GRASSFIELD_LANG=${2:?--lang needs a value}; shift ;;
    --desktop-dir) export GRASSFIELD_DESKTOP_DIR=${2:?--desktop-dir needs a path}; shift ;;
    --menu-bridge) export GRASSFIELD_MENU_BRIDGE=${2:?--menu-bridge needs a path}; shift ;;
    --desktop-screen) export GRASSFIELD_DESKTOP_SCREEN=${2:?--desktop-screen needs an output name}; shift ;;
    --cursor-theme) export GRASSFIELD_CURSOR_THEME=${2:?--cursor-theme needs a theme name}; shift ;;
    # GF-REF at a fractional scale, like the owner's 1.25 panel (config/hypr/dev.lua accepts 1, 1.25, 1.5, 1.75, 2 only).
    --ref-scale) export GRASSFIELD_REF_SCALE=${2:?--ref-scale needs a scale}; shift ;;
    -h|--help) echo "usage: nested-up.sh [--cursor-theme grassfield-cursors-custom] [--session-bus] [--no-plugin] [--render-timing] [--migrated] [--unit-env] [--visual-fixtures] [--lang LL] [--desktop-dir PATH] [--desktop-screen NAME] [--menu-bridge PATH] [--ref-scale 1|1.25|1.5|1.75|2]"; exit 0 ;;
    *) echo "nested-up: unknown option $1" >&2; exit 2 ;;
  esac
  shift
done
dev=$root/.dev
# shellcheck source=pidfile.sh
. "$root/scripts/dev/pidfile.sh"
# A record written inside the sandbox's PID namespace names another process on the host (incident 2026-10-18).
dev_require_host nested-up
mkdir -p "$dev/state" "$dev/config" "$dev/shots"
# The composed icon theme for dev sessions (ADR-0017): pinned GitHub sources composed under .dev/share, selected by
# devenv.sh. Failure is not fatal: devenv.sh falls back to the wrapper theme (Breeze, Adwaita, hicolor). icons.sh returns
# at once when its stamp matches; its network steps have time limits.
"$root/scripts/dev/icons.sh" \
  || echo "nested-up: composed icons not provisioned (continuing with the wrapper theme; retry: scripts/dev/icons.sh)" >&2
# shellcheck source=devenv.sh
. "$root/scripts/dev/devenv.sh"

if running=$(dev_live_pid "$dev/nested.pid"); then
  echo "nested-up: already running (pid $running, instance $(<"$dev/nested.instance"))"
  exit 0
fi

[[ -n ${HYPRLAND_INSTANCE_SIGNATURE:-} && -n ${WAYLAND_DISPLAY:-} ]] \
  || { echo "nested-up: must run inside a Hyprland session (HYPRLAND_INSTANCE_SIGNATURE/WAYLAND_DISPLAY unset)" >&2; exit 1; }

# 1. Record the owner's main instance. The previous run's instance/socket records go first: they are written again only
#    once Hyprland lists the new instance, so no failed start can leave them next to a new process record.
printf '%s\n' "$HYPRLAND_INSTANCE_SIGNATURE" > "$dev/main.instance"
rm -f "$dev/nested.instance" "$dev/nested.wayland"

# Plugin to load at startup (C2: GRASSFIELD_NO_PLUGIN=1 starts without it).
plugin=${GRASSFIELD_PLUGIN:-$root/compositor/build/grassfield-compositor.so}
[[ -f $plugin && -z ${GRASSFIELD_NO_PLUGIN:-} ]] || plugin=""

# The shell tree the bindings address (`qs ipc -p`): the source, or with --migrated the packaged form shell-run.sh builds.
shell_dir=$root/shell
if [[ ${GRASSFIELD_MIGRATED:-0} == 1 ]]; then
  # Built now (shell-run.sh finds the same stamp later) and addressed by its REAL path, as the processes are started: the link is
  # never a process's path (scripts/dev/migrated-tree.sh). The path is built from the stamp it printed, not read back from the link,
  # which a concurrent build could have repointed after it released its lock.
  tree_stamp=$("$root/scripts/dev/migrated-tree.sh" "$root" "$dev") || { echo "nested-up: the migrated tree did not build" >&2; exit 1; }
  [[ $tree_stamp =~ ^[0-9a-f]{16}$ && ! -L $dev/migrated-$tree_stamp && -d $dev/migrated-$tree_stamp ]] \
    || { echo "nested-up: the migrated tree $dev/migrated-$tree_stamp is missing" >&2; exit 1; }
  shell_dir=$dev/migrated-$tree_stamp/shell
fi

# 2. Start Hyprland nested. Its children inherit the nested WAYLAND_DISPLAY/HYPRLAND_INSTANCE_SIGNATURE.
env -u HYPRLAND_INSTANCE_SIGNATURE -u HYPRLAND_CMD -u DISPLAY \
  GRASSFIELD_CONFIG_DIR="$root/config/hypr" \
  GRASSFIELD_SHELL_DIR="$shell_dir" \
  GRASSFIELD_STATE_HOME="$dev/state" \
  GRASSFIELD_CONFIG_HOME="$dev/config" \
  GRASSFIELD_DEV=1 \
  GRASSFIELD_PLUGIN="$plugin" \
  setsid Hyprland --config "$root/config/hypr/dev.lua" >"$dev/hyprland.log" 2>&1 </dev/null &
pid=$!
dev_record_pid "$dev/nested.pid" "$pid"

# 3. Wait for the new instance (matched by PID) and record its signature and Wayland socket.
sig="" sock=""
for _ in $(seq 1 100); do
  if ! kill -0 "$pid" 2>/dev/null; then
    echo "nested-up: Hyprland exited early; see .dev/hyprland.log" >&2
    tail -n 20 "$dev/hyprland.log" >&2 || true
    rm -f "$dev/nested.pid" "$dev/nested.pid.start"
    exit 1
  fi
  line=$(hyprctl instances -j | jq -r --argjson p "$pid" '.[] | select(.pid == $p) | "\(.instance) \(.wl_socket)"')
  if [[ -n $line ]]; then
    read -r sig sock <<<"$line"
    break
  fi
  sleep 0.1
done
[[ -n $sig ]] || { echo "nested-up: timed out waiting for the nested instance" >&2; exit 1; }
if [[ $sig == "$(<"$dev/main.instance")" ]]; then
  echo "nested-up: refusing: new instance equals the main instance" >&2
  exit 1
fi
printf '%s\n' "$sig" > "$dev/nested.instance"
printf '%s\n' "$sock" > "$dev/nested.wayland"
echo "nested-up: pid $pid, instance $sig, socket $sock, plugin ${plugin:-none}"

# 4. Start grassfield-shell against the nested instance, if it exists yet. Unless --session-bus, shell-run.sh
#    also starts the private bus and grassfield-menu-bridge on it (before any test app; ADR-0008). The bridge
#    binary: --menu-bridge PATH, else .dev/build/grassfield-menu-bridge (bridges/menu-bridge/build-direct.sh).
if [[ -f $root/shell/shell.qml ]]; then
  "$root/scripts/dev/shell-run.sh"
fi
