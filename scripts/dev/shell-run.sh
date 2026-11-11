#!/usr/bin/env bash
# (Re)start grassfield-shell inside the nested instance only. Never against the owner's session (R3).
#
# The security process (ADR-0041 step 1, S2 and S3: `qs -p shell/security.qml`, the lock, idle, the sleep inhibitor, the
# polkit agent and the secret sheets; in a real session grassfield-security.service) runs beside it with the same
# environment, its own record (.dev/security.pid) and log (.dev/security.log). A plain run starts it when it is not running and leaves a running one alone, as systemd does: a
# restart of the UI never touches the lock. `--security` (re)starts the security process only, as its unit's Restart=
# would after a crash (the lock survival tests kill it and bring it back this way); the UI is left alone.
#
# Private D-Bus session bus (the default; --session-bus or GRASSFIELD_PRIVATE_BUS=0 keeps the owner's session bus for
# the rare test that needs it): the shell owns org.freedesktop.Notifications without touching the owner's session, and
# the bus starts nothing of the machine: scripts/dev/dev-bus.conf has no service folder, so no D-Bus activatable handler,
# gvfs, keyring, dconf or portal can run on it with the owner's XDG_RUNTIME_DIR (security counter-review of f9e24e1, LOW-2;
# ADR-0011). The bus daemon still starts with the XDG_* homes under .dev/apps-home and GRASSFIELD_DEV=1. One dbus-daemon per
# nested session (socket in /tmp as with dbus-run-session: libdbus caps socket paths at 99 bytes, too short for .dev/ in a
# worktree), started by the first shell start and reused by shell restarts, so applications on it keep their connection as
# on a real session bus; nested-down.sh stops it. A bus that can start anything (one kept from a run before this
# configuration) is refused (scripts/dev/dev-bus-check.sh). The address is in .dev/bus.address for test clients
# (notify-send, busctl --address, test apps).
#
# Global menus (ADR-0008): with the private bus, grassfield-menu-bridge (.dev/build/grassfield-menu-bridge
# from bridges/menu-bridge/build-direct.sh, or GRASSFIELD_MENU_BRIDGE) is (re)started on that bus before
# the shell and before any test app: socket .dev/run/menu-bridge.sock, log .dev/menu-bridge.log. It owns
# com.canonical.AppMenu.Registrar only after the shell's hello reports the plugin's appmenu feature. It is
# NEVER started on the owner's session bus (no private bus: no bridge; the bridge refuses that bus too).
set -euo pipefail

root=$(git -C "$(dirname "$0")" rev-parse --show-toplevel)

# Same options as nested-up.sh (bare commands match the sandbox exclusion; env prefixes may not).
only_security=0
migrated=${GRASSFIELD_MIGRATED:-0}
while [[ $# -gt 0 ]]; do
  case $1 in
    --private-bus) export GRASSFIELD_PRIVATE_BUS=1 ;;
    --session-bus) export GRASSFIELD_PRIVATE_BUS=0 ;;
    --visual-fixtures) export GRASSFIELD_VISUAL_FIXTURES=1 ;;  # test hooks and fixed values (shell/services/VisualFixtures.qml, dev only)
    --render-timing) export GRASSFIELD_RENDER_TIMING=1 ;;  # Qt scene graph frame timing in .dev/shell.log (QSG_RENDER_TIMING)
    --lang) export GRASSFIELD_LANG=${2:?--lang needs a value}; shift ;;
    --desktop-dir) export GRASSFIELD_DESKTOP_DIR=${2:?--desktop-dir needs a path}; shift ;;
    --menu-bridge) export GRASSFIELD_MENU_BRIDGE=${2:?--menu-bridge needs a path}; shift ;;
    --desktop-screen) export GRASSFIELD_DESKTOP_SCREEN=${2:?--desktop-screen needs an output name}; shift ;;
    --cursor-theme) export GRASSFIELD_CURSOR_THEME=${2:?--cursor-theme needs a theme name}; shift ;;
    --migrated) migrated=1 ;;  # the UI runs the packaged form (ADR-0056): .dev/migrated/shell, rebuilt when shell/ changes. The key bindings
                               # still address -p <repo>/shell: use `qs ipc --pid $(cat .dev/shell.pid)` (tests/visual/ipc.sh) with it.
    --unit-env) export GRASSFIELD_UNIT_ENV=1 ;;  # the shell gets grassfield-shell.service's own variables (file watcher off, as packaged)
    --security) only_security=1 ;;  # (re)start the security process only (ADR-0041 S2), the UI left alone
    *) echo "shell-run: unknown option $1" >&2; exit 2 ;;
  esac
  shift
done
# X11 clients started from a dev session (the shell, the private bus, apps) must never reach the owner's X server
# (their Xwayland :0): no DISPLAY is passed on. X11-only apps do not start in dev sessions.
unset DISPLAY
dev=$root/.dev
# shellcheck source=pidfile.sh
. "$root/scripts/dev/pidfile.sh"
# A record written inside the sandbox's PID namespace names another process on the host (incident 2026-10-18).
dev_require_host shell-run
# shellcheck source=devenv.sh
. "$root/scripts/dev/devenv.sh"
apps_home=$dev/apps-home
# Only this tree's live nested compositor: after a nested crash its socket name can be reused by another worktree's
# session, and a shell started there would take a session lock only the owner's password releases.
dev_nested_target "$dev" || exit 1
sig=$DEV_NESTED_SIG
sock=$DEV_NESTED_SOCK

shell_dir=$root/shell
# `--security` without --migrated while the UI runs the migrated tree (its record below) would start security from the source
# tree, where the UI's lock requests never arrive: refused (review of #40, LOW-2).
if ((only_security)) && [[ $migrated != 1 && -s $dev/ui.tree ]]; then
  echo "shell-run: --security: the UI runs the migrated tree (.dev/ui.tree): add --migrated, or restart the UI without it" >&2
  exit 1
fi
if [[ $migrated == 1 ]]; then
  # The packaged form of the UI tree (scripts/dev/migrate-qs-imports.py, ADR-0056): file: URLs, so Qt's QML disk cache serves
  # it. The parents of shell/ that dev code reaches (../VERSION, ../packaging, ../branding, ../.dev) are links to the repository.
  # scripts/dev/migrated-tree.sh never deletes or rewrites a tree a process may use: a changed source is built into a fresh
  # directory and .dev/migrated is repointed with one rename; its stamp names the tree content (security_sig below).
  if ((only_security)); then
    # `--security` never builds: the running UI addresses `<its tree>/security.qml`, so the security process starts from the tree
    # the UI was started from (the stamp recorded in .dev/ui.tree when it started), even if shell/ changed since.
    tree_stamp=$(cat "$dev/ui.tree" 2>/dev/null || true)
    [[ $tree_stamp =~ ^[0-9a-f]{16}$ ]] || { echo "shell-run: --security --migrated: no record of the migrated tree the UI runs from (.dev/ui.tree): start the UI first (shell-run.sh --migrated)" >&2; exit 1; }
  else
    tree_stamp=$("$root/scripts/dev/migrated-tree.sh" "$root" "$dev") || { echo "shell-run: the migrated tree did not build" >&2; exit 1; }
    [[ $tree_stamp =~ ^[0-9a-f]{16}$ ]] || { echo "shell-run: migrated-tree.sh printed no stamp: '$tree_stamp'" >&2; exit 1; }
  fi
  # Started and addressed by the REAL path of the stamped tree, built from the stamp migrated-tree.sh printed (it decided under
  # its lock), never through the .dev/migrated link: a concurrent build could repoint the link after the lock was released, and
  # Quickshell keeps the literal path, so the process would run another tree than the one security_sig names.
  tree_dir=$dev/migrated-$tree_stamp
  if [[ -L $tree_dir || ! -d $tree_dir ]]; then
    hint=""; ((only_security)) && hint=" (the one the UI was started from: restart the UI)"
    echo "shell-run: the migrated tree $tree_dir is gone or not a directory$hint" >&2
    exit 1
  fi
  shell_dir=$tree_dir/shell
fi
# The shell runs as a session leader (setsid): its whole group stops, so that no orphaned qs stays behind. Only a record
# that still matches its process is signalled (scripts/dev/pidfile.sh). `--security` stops the security process instead
# (below); the UI keeps running.
if ((only_security)); then
  dev_stop "$dev/security.pid" grassfield-security >/dev/null || exit 1
else
  dev_stop "$dev/shell.pid" grassfield-shell >/dev/null || exit 1
fi

# The security process runs from the same tree as the UI: the UI's lock requests (shell/security/lock LockClient) and the key
# bindings address `<shell dir>/security.qml`, and an instance is identified by its path. With --migrated that is the migrated
# tree's security.qml (kept verbatim by the migration, loaded through qs: as in the package); without it, the source tree's.
security_qml=$shell_dir/security.qml
launch=(qs -p "$shell_dir" --log-times --no-color)
private=""
bus_env=()
bridge_sock=""
if [[ ${GRASSFIELD_PRIVATE_BUS:-1} == 1 ]]; then
  command -v dbus-daemon >/dev/null || { echo "shell-run: dbus-daemon not found" >&2; exit 1; }
  mkdir -p "$dev/run"
  chmod 700 "$dev/run"
  # sockaddr_un.sun_path: 107 bytes for the bridge socket.
  ((${#dev} + 21 < 108)) || { echo "shell-run: $dev is too long for the bridge's Unix socket path" >&2; exit 1; }
  if ! { [[ -s $dev/bus.address ]] && dev_live_pid "$dev/bus.pid" >/dev/null; }; then
    dev_stop "$dev/bus.pid" "private D-Bus bus" >/dev/null || exit 1
    rm -f "$dev/bus.address" "$dev/bus.address.new"
    # The session bus's configuration without any service folder (scripts/dev/dev-bus.conf: nothing is activatable but the
    # bus itself). The nested Wayland socket and the isolated homes stay in its environment (ADR-0011).
    mkdir -p "$apps_home"/{config,cache,state,data,home}
    env WAYLAND_DISPLAY="$sock" HYPRLAND_INSTANCE_SIGNATURE="$sig" GRASSFIELD_DEV=1 HOME="$apps_home/home" \
      XDG_CONFIG_HOME="$apps_home/config" XDG_CACHE_HOME="$apps_home/cache" XDG_STATE_HOME="$apps_home/state" \
      XDG_DATA_HOME="$apps_home/data" \
      setsid dbus-daemon --config-file="$root/scripts/dev/dev-bus.conf" --nofork --print-address=1 \
      >"$dev/bus.address.new" 2>"$dev/bus.log" </dev/null &
    dev_record_pid "$dev/bus.pid" "$!"
    for _ in $(seq 1 50); do [[ -s $dev/bus.address.new ]] && break; sleep 0.1; done
    [[ -s $dev/bus.address.new ]] || { echo "shell-run: the private bus did not start (see .dev/bus.log)" >&2; exit 1; }
    head -n 1 "$dev/bus.address.new" >"$dev/bus.address"
    rm -f "$dev/bus.address.new"
  fi
  bus=$(<"$dev/bus.address")
  case $bus in
    unix:path=/tmp/dbus-*) ;;
    *) echo "shell-run: refusing: unexpected private bus address $bus" >&2; exit 1 ;;
  esac
  # Nothing but the bus itself is activatable on it, also on a bus kept from an earlier run (one started with the standard
  # session folders before dev-bus.conf is refused: it would start gvfs, the keyring, dconf or a portal on demand), else the
  # shell does not start. A service such a bus already started cannot be stopped from here: restart the nested session.
  if ! unexpected=$("$root/scripts/dev/dev-bus-check.sh" "$bus"); then
    echo "shell-run: refusing: the private bus can start services of the machine or could not be checked (${unexpected//$'\n'/, }): just nested-down, then just nested-up" >&2
    exit 1
  fi
  bus_env=(DBUS_SESSION_BUS_ADDRESS="$bus")
  private=1

  # grassfield-menu-bridge on the private bus, (re)started with the shell (not by `--security`: it serves the UI).
  bridge=${GRASSFIELD_MENU_BRIDGE:-$dev/build/grassfield-menu-bridge}
  if ((only_security)); then
    [[ -S $dev/run/menu-bridge.sock ]] && bridge_sock=$dev/run/menu-bridge.sock
  elif ! dev_stop "$dev/menu-bridge.pid" grassfield-menu-bridge >/dev/null; then
    exit 1
  elif [[ -x $bridge ]]; then
    bridge_sock=$dev/run/menu-bridge.sock
    env -u GRASSFIELD_SESSION DBUS_SESSION_BUS_ADDRESS="$bus" GRASSFIELD_DEV=1 GRASSFIELD_MENU_BRIDGE_SOCKET="$bridge_sock" \
      setsid "$bridge" >"$dev/menu-bridge.log" 2>&1 </dev/null &
    dev_record_pid "$dev/menu-bridge.pid" "$!"
    for _ in $(seq 1 30); do [[ -S $bridge_sock ]] && break; sleep 0.1; done
    [[ -S $bridge_sock ]] || { echo "shell-run: grassfield-menu-bridge did not start (see .dev/menu-bridge.log)" >&2; bridge_sock=""; }
  else
    echo "shell-run: no menu bridge ($bridge; build it with bridges/menu-bridge/build-direct.sh): T0 menus only" >&2
  fi
elif ((!only_security)); then
  # Without a private bus there is no bridge: a leftover one would serve the wrong shell.
  dev_stop "$dev/menu-bridge.pid" grassfield-menu-bridge >/dev/null || exit 1
fi

# Grassfield Settings built by apps/settings/build-direct.sh (menu item "System Settings…" in dev).
settings_cmd=${GRASSFIELD_SETTINGS_CMD:-}
[[ -z $settings_cmd && -x $dev/build/grassfield-settings ]] && settings_cmd=$dev/build/grassfield-settings

# Grassfield Preview built by apps/preview/build-direct.sh (Space on a desktop icon opens Glance in dev).
preview_cmd=${GRASSFIELD_PREVIEW_CMD:-}
[[ -z $preview_cmd && -x $dev/build/grassfield-preview ]] && preview_cmd=$dev/build/grassfield-preview

# Grassfield Files built by apps/files/build-direct.sh (the dev open policy opens folders in it, scripts/dev/open-policy.sh).
files_cmd=${GRASSFIELD_FILES_CMD:-}
[[ -z $files_cmd && -x $dev/build/grassfield-files ]] && files_cmd=$dev/build/grassfield-files

# Apps started from the shell in dev (System Settings, Glance) run through the isolating helper: XDG_* under .dev/,
# GRASSFIELD_*_HOME shared with this shell (the command is split on spaces by the shell; .dev paths have none).
isolate=("$root/scripts/dev/isolated.sh" --name shell --config-home "$dev/config" --state-home "$dev/state" --)
[[ -n $settings_cmd ]] && settings_cmd="${isolate[*]} $settings_cmd"
[[ -n $preview_cmd ]] && preview_cmd="${isolate[*]} $preview_cmd"
[[ -n $files_cmd ]] && files_cmd="${isolate[*]} $files_cmd"
# Dev open policy: the shell never asks GIO or xdg-open to start an app (ADR-0011). One refusal line per refused open.
open_policy=$root/scripts/dev/open-policy.sh
open_log=$dev/open-policy.log
# Optional plocate database for the Search file provider (a test database of a sandbox folder, never the owner's files):
# .dev/plocate.db when present (updatedb --database-root DIR --output .dev/plocate.db --require-visibility no).
plocate_db=""
[[ -s $dev/plocate.db ]] && plocate_db=$dev/plocate.db

# --render-timing (GRASSFIELD_RENDER_TIMING=1): opt-in Qt scene graph render timing (QSG_RENDER_TIMING) in the shell log.
# Only this start of the shell has it: a start without the option is quiet again.
timing=()
[[ ${GRASSFIELD_RENDER_TIMING:-} == 1 ]] && timing=(QSG_RENDER_TIMING=1)
# --unit-env: the Environment= line of packaging/systemd/grassfield-shell.service, so that a nested run reproduces the
# packaged shell (devenv.sh clears these when they are only inherited from a live session).
[[ ${GRASSFIELD_UNIT_ENV:-} == 1 ]] && timing+=(QS_DISABLE_FILE_WATCHER=1 QS_NO_RELOAD_POPUP=1)
# ... and its UnsetEnvironment= (review of 360d6fa): the QML and Qt plugin search paths and Quickshell's config selectors
# of the calling environment are dropped. QML_IMPORT_PATH below is then only this tree's own module roots, standing in
# for the packaged shell's Qt built-in import path (/usr/lib/qt6/qml).
# Quickshell's crash handler is off in both units (packaging/systemd/grassfield-*.service, ADR-0041 S2), and here always:
# with it, a SIGSEGV leaves the recorded process alive while a child it forked runs a relaunched shell, so .dev/*.pid no
# longer names the running instance and the crash steps of tests/security/reload_locked.sh (ui-crash) see no exit. As in
# the units' LimitCORE=0 (the opus delta review of 122f8d67), both processes started below write no core file: the journal
# keeps the crash (coredumpctl list), without a stack (run qs by hand to debug a crash with a core).
crash_env=(QS_DISABLE_CRASH_HANDLER=1)
ulimit -c 0
unit_unset=()
if [[ ${GRASSFIELD_UNIT_ENV:-} == 1 ]]; then
  for var in $(sed -n 's/^UnsetEnvironment=//p' "$root/packaging/systemd/grassfield-shell.service"); do
    unit_unset+=(-u "$var")
  done
fi

# Grassfield.I18n (ui/i18n) and the compiled catalogs (scripts/dev/i18n-build.sh), rebuilt when stale.
"$root/ui/i18n/build-direct.sh" >&2
"$root/scripts/dev/i18n-build.sh" >&2

# grassfield-stack-helper (ADR-0025, the Dock's folder stacks): built when missing or older than its sources or Files'
# filelogic it compiles in. The build runs in the background and is waited for one second at most (a build of the helper took
# 56 s on a loaded machine and held the shell back): the shell starts at once, the Dock asks for the helper again every 5 s
# until it is there and shows the folder icon meanwhile, and a stale helper is used until the new one is moved into place
# (build-direct.sh moves it atomically). A failed build never stops the shell: one line here and the log.
stack_helper=$dev/build/grassfield-stack-helper
if [[ ! -x $stack_helper || -n $(find "$root/apps/stack-helper/src" "$root/apps/files/src/filelogic.cpp" "$root/apps/files/src/filelogic.h" "$root/apps/stack-helper/build-direct.sh" -newer "$stack_helper" -print -quit 2>/dev/null) ]]; then
  (
    "$root/apps/stack-helper/build-direct.sh" >"$dev/stack-helper-build.log" 2>&1 ||
      echo "shell-run: the stack helper did not build (see $dev/stack-helper-build.log): folder stacks show the folder icon" >>"$dev/stack-helper-build.log"
  ) </dev/null >/dev/null 2>&1 &
  build_pid=$!
  for _ in 1 2 3 4 5 6 7 8 9 10; do
    kill -0 "$build_pid" 2>/dev/null || break
    sleep 0.1
  done
  if kill -0 "$build_pid" 2>/dev/null; then
    echo "shell-run: the stack helper is still building in the background (log $dev/stack-helper-build.log)" >&2
  elif [[ ! -x $stack_helper ]]; then
    echo "shell-run: the stack helper did not build (see $dev/stack-helper-build.log): folder stacks show the folder icon" >&2
  fi
fi

# grassfield-clipboard-helper (ADR-0034, the clipboard history): built the same way, in the background, when missing or older
# than its sources. The dev shell gives it the nested compositor's socket only (GRASSFIELD_CLIPBOARD_DISPLAY below, an absolute
# path): it never watches the owner's display, and the shell starts no helper without that variable.
clipboard_helper=$dev/build/grassfield-clipboard-helper
if [[ ! -x $clipboard_helper || -n $(find "$root/apps/clipboard-helper/src" "$root/apps/clipboard-helper/protocols" "$root/apps/clipboard-helper/build-direct.sh" -newer "$clipboard_helper" -print -quit 2>/dev/null) ]]; then
  (
    "$root/apps/clipboard-helper/build-direct.sh" >"$dev/clipboard-helper-build.log" 2>&1 ||
      echo "shell-run: the clipboard helper did not build (see $dev/clipboard-helper-build.log): no clipboard history" >>"$dev/clipboard-helper-build.log"
  ) </dev/null >/dev/null 2>&1 &
fi
if [[ $sock == /* ]]; then clipboard_display=$sock; else clipboard_display=${XDG_RUNTIME_DIR:?}/$sock; fi

# The isolated trash of the dev session (shell/services/Trash.qml watches it; ADR-0011): the shell's "Move to Trash"
# and the Dock's Trash drop put files here, never in the owner's ~/.local/share/Trash.
mkdir -p "$dev/apps-home/data/Trash/files" "$dev/apps-home/data/Trash/info" "$dev/apps-home/home"

# Desktop icons: the folder is a sandbox in dev (never the owner's real desktop); an exported
# GRASSFIELD_DESKTOP_DIR wins.
desktop_dir=${GRASSFIELD_DESKTOP_DIR:-$dev/desktop-sandbox}

# Dev sessions never idle-lock (only the owner's password unlocks the nested lock screen): seed
# lock.idleMinutes: 0 ("never", shell/security/idle/IdleModel.js) in the DEV config when the key is absent.
# An existing value is kept. The shell's defaults and production code are untouched.
cfg=$dev/config/grassfield.json
mkdir -p "$dev/config"
if [[ ! -s $cfg ]]; then
  printf '{\n  "version": 1,\n  "lock": {\n    "idleMinutes": 0\n  }\n}\n' >"$cfg"
elif jq -e '.lock.idleMinutes == null' "$cfg" >/dev/null 2>&1; then
  jq '.lock.idleMinutes = 0' "$cfg" >"$cfg.new" && mv "$cfg.new" "$cfg"
fi
# The dev Dock pins only foot (when dock.pinned is absent): a mis-click or a test's coordinate click on a pinned tile
# then starts a terminal, never a browser or a file manager on the owner's profile/home (incidents 2026-10-17/18).
if jq -e '.dock.pinned == null' "$cfg" >/dev/null 2>&1; then
  jq '.dock.pinned = ["foot"]' "$cfg" >"$cfg.new" && mv "$cfg.new" "$cfg"
fi
# No folder stack by default in dev (the shell's default is ~/Downloads: a nested Dock would pile up the owner's real downloads).
if jq -e '.dock.folders == null' "$cfg" >/dev/null 2>&1; then
  jq '.dock.folders = []' "$cfg" >"$cfg.new" && mv "$cfg.new" "$cfg"
fi

# The security process (ADR-0041 S2): the same environment as the shell below (the nested compositor, the private bus, the
# dev config and state, GRASSFIELD_DEV=1), its own record and log. Started when it is not running (a plain run) or always
# (`--security`, after the stop above); a restart of the UI leaves a running one alone, unless the settings it was started
# with changed (the language, the visual fixtures and fixed time, the private bus, the unit environment, the L2 PAM opt-in,
# the secret sheets' test socket since S3: .dev/security.sig), as when the visual suite switches language: then it is
# restarted too.
security_sig="migrated=$migrated tree=${tree_stamp:-} lang=${GRASSFIELD_LANG:-} fixtures=${GRASSFIELD_VISUAL_FIXTURES:-} time=${GRASSFIELD_FIXED_TIME:-} bus=$private unit=${GRASSFIELD_UNIT_ENV:-} pam=${GRASSFIELD_DEV_ALLOW_PAM:-} prompter=${GRASSFIELD_PROMPTER_SOCKET:-}"
start_security() {
  # The security modules read no GRASSFIELD_* variable but the dev gate's (ADR-0019): the lock finds the UI's wallpaper.json
  # under $XDG_STATE_HOME/grassfield, here a link to the dev state the shell writes (.dev/state).
  mkdir -p "$dev/security-xdg-state"
  ln -sfn "$dev/state" "$dev/security-xdg-state/grassfield"
  env "${unit_unset[@]}" "${timing[@]}" "${crash_env[@]}" "${bus_env[@]}" PATH="$root/scripts/dev/open-shims:$PATH" \
    WAYLAND_DISPLAY="$sock" HYPRLAND_INSTANCE_SIGNATURE="$sig" XDG_STATE_HOME="$dev/security-xdg-state" \
    GRASSFIELD_STATE_HOME="$dev/state" GRASSFIELD_CONFIG_HOME="$dev/config" GRASSFIELD_DEV=1 \
    GRASSFIELD_PRIVATE_BUS="$private" \
    QT_QPA_PLATFORM=wayland QT_NO_XDG_DESKTOP_PORTAL=1 QML_IMPORT_PATH="$root/ui:$dev/build/qml" GRASSFIELD_TRANSLATIONS_DIR="$dev/translations" \
    setsid qs -p "$security_qml" --log-times --no-color >"$dev/security.log" 2>&1 </dev/null &
  local security_pid=$!
  dev_record_pid "$dev/security.pid" "$security_pid"
  printf '%s\n' "$security_sig" >"$dev/security.sig"
  echo "shell-run: grassfield-security pid $security_pid (log .dev/security.log)"
}
if ((only_security)); then
  start_security
  exit 0
fi
if dev_live_pid "$dev/security.pid" >/dev/null; then
  if [[ $(cat "$dev/security.sig" 2>/dev/null) != "$security_sig" ]]; then
    echo "shell-run: the security process was started with other settings; restarting it too" >&2
    dev_stop "$dev/security.pid" grassfield-security >/dev/null || exit 1
    start_security
  fi
else
  start_security
fi

# The open shims (gio, xdg-open, gtk-launch -> open-policy.sh) come first on the shell's PATH: QProcess resolves a program
# on the PATH of its parent, so code that runs `gio open` in a Process (shell/desktop/DesktopFiles.qml) gets the policy too.
env "${unit_unset[@]}" "${timing[@]}" "${crash_env[@]}" "${bus_env[@]}" PATH="$root/scripts/dev/open-shims:$PATH" GRASSFIELD_MENU_BRIDGE_SOCKET="$bridge_sock" \
  GRASSFIELD_DESKTOP_DIR="$desktop_dir" WAYLAND_DISPLAY="$sock" HYPRLAND_INSTANCE_SIGNATURE="$sig" \
  GRASSFIELD_STATE_HOME="$dev/state" GRASSFIELD_CONFIG_HOME="$dev/config" GRASSFIELD_DEV=1 \
  GRASSFIELD_PRIVATE_BUS="$private" GRASSFIELD_SETTINGS_CMD="$settings_cmd" GRASSFIELD_PREVIEW_CMD="$preview_cmd" \
  GRASSFIELD_FILES_CMD="$files_cmd" GRASSFIELD_OPEN_POLICY="$open_policy" GRASSFIELD_OPEN_LOG="$open_log" \
  GRASSFIELD_SEARCH_PLOCATE_DB="$plocate_db" GRASSFIELD_CURSORS_BUILD="$root/branding/cursors/build.sh" \
  GRASSFIELD_CURSORS_ICONS="$dev/share/icons" GRASSFIELD_CLIPBOARD_DISPLAY="$clipboard_display" \
  QT_QPA_PLATFORM=wayland QT_NO_XDG_DESKTOP_PORTAL=1 QML_IMPORT_PATH="$root/ui:$dev/build/qml" GRASSFIELD_TRANSLATIONS_DIR="$dev/translations" \
  setsid "${launch[@]}" >"$dev/shell.log" 2>&1 </dev/null &
shell_pid=$!
dev_record_pid "$dev/shell.pid" "$shell_pid"
# The tree the UI runs from, for `--security` (above): written once the new UI is started (a refused stop above leaves the old UI
# and its record together; review of #40, LOW-1), removed when the UI runs the source tree.
if [[ $migrated == 1 ]]; then printf '%s\n' "$tree_stamp" >"$dev/ui.tree"; else rm -f "$dev/ui.tree"; fi
echo "shell-run: grassfield-shell pid $shell_pid (log .dev/shell.log${private:+, private bus: .dev/bus.address}${bridge_sock:+, menu bridge: .dev/menu-bridge.log})"
