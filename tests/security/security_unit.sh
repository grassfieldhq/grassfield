#!/usr/bin/env bash
# ADR-0041 step 1, S1 (the owner's SQ-1 B): the security process runs beside the UI; since S2 it hosts the lock, idle and
# the sleep inhibitor (shell/security/host/SecurityHost.qml) and the UI holds none of them. Static (data layer): the root
# shell/security.qml (a root of its own next to shell.qml, imports only QtQuick, Quickshell, Quickshell.Io and
# qs.security.host, never reloads on a file change, one SecurityHost, one IpcHandler `security` with `state` and `heartbeat`;
# the reviewed file
# is pinned by its SHA-256, comments included, so any change needs the opus security review and then the new hash here
# (the integrator's decision on #75: a static check cannot model all of QML); tests/security/root_check.py stays as the
# readable second check, an allow-list of identifiers, imports and types read as the engine reads them, with a selftest of
# planted mutants),
# grassfield-security.service (loads that root by path from the system tree, the same cleared environment as the UI's
# unit, Restart=always with a start limit a loop reaches, session-only, no NoNewPrivileges for the helpers of S2/S3, memory
# guards from the measurement and the UI unit's CPU quota, OnFailure=omarchy-sleep-lock.service since S2 while the UI's
# unit lost it), the autostart (started just before the shell, --no-block), the PKGBUILD, grassfield-security-status
# (read-only, calls the targets by the unit's path), the IPC surface table, and the S2 scan
# (tests/security/security_process_scan.py: no lock or idle in the UI tree, one Idle in the host, no UI service in the
# security process). qmllint parses the root when it is installed. Plain shell test: PASS/FAIL lines, non-zero on failure.
set -euo pipefail
root=$(git -C "$(dirname "$0")" rev-parse --show-toplevel)
cd "$root"
fail=0
check() { if "$@"; then echo "PASS: security unit $desc"; else echo "FAIL: security unit $desc"; fail=1; fi; }
qml=shell/security.qml
unit=packaging/systemd/grassfield-security.service
ui=packaging/systemd/grassfield-shell.service
helper=packaging/bin/grassfield-security-status

desc="root: a root of its own next to shell.qml"
check bash -c '[[ -f "$1" && -f shell/shell.qml ]]' _ "$qml"
# The reviewed root, pinned. A change to shell/security.qml, comments included, fails here until the opus security review
# of that change has passed and the hash below is updated in the same pull request (the integrator's decision on #75).
pinned=452918e2a1db7b4b9d5ae1c8db8715df2e7e6e63fef5980f9526ec98947f482c
desc="root: the reviewed file is pinned by its SHA-256 (any change: security review required, then update the pinned hash)"
check bash -c '[[ "$(sha256sum "$1" | cut -d" " -f1)" == "$2" ]] || { echo "shell/security.qml changed: security review required, then update the pinned hash" >&2; exit 1; }' _ "$qml" "$pinned"
desc="root: the readable second check (tests/security/root_check.py): ASCII only, no backslash, no regex literal, template string or bracket outside strings; every identifier one the root uses today; imports QtQuick, Quickshell, Quickshell.Io and qs.security.host only, wherever they stand; ShellRoot, SecurityHost and IpcHandler the only types; one SecurityHost; one IpcHandler, target security, the functions state and heartbeat only"
check python3 -I tests/security/root_check.py "$qml"
desc="root check selftest: the root passes (with LF and with CRLF) and each of the 38 planted mutants (next-line braces, comments before braces, indented imports, a singleton's property, names as strings or through Reflect, a U+2028 ending a comment, Unicode escapes, a second IpcHandler, an animation, Quickshell.reload, a third function, a renamed target, a second SecurityHost, the lock, idle, polkit or qs.security module imported into the root, ...) is refused"
check python3 -I tests/security/root_check.py --selftest "$qml"
desc="root: never reloads on a file change (settings.watchFiles: false)"
check grep -qE '^\s*settings\.watchFiles: false' "$qml"
desc="root: one IpcHandler, target security, functions state and heartbeat, and nothing else that answers IPC"
check bash -c '[[ $(grep -c "IpcHandler {" "$1") == 1 ]] && grep -qE "^\s*target: \"security\"" "$1" && grep -qE "^\s*function state\(\): string" "$1" && grep -qE "^\s*function heartbeat\(\): string" "$1" && [[ $(grep -cE "^\s*function " "$1") == 2 ]]' _ "$qml"
desc="host: logs the ready line the start-time measurement reads (shell/security/host/SecurityHost.qml, instantiated by the root)"
check bash -c 'grep -q "grassfield-security: ready" shell/security/host/SecurityHost.qml && grep -qE "^\s*SecurityHost \{" "$1"' _ "$qml"
desc="S2 scan (tests/security/security_process_scan.py): the UI tree imports neither the lock nor idle and names no Lock, Idle or SleepInhibitor (no Lock.lock caller left in the UI); one Idle in the host; the lock and idle use no UI module and only the qs.services types Settings, VisualFixtures, FixedTime and WallClock; one definition of the state file"
check python3 -I tests/security/security_process_scan.py "$root"
desc="S2 scan selftest: the tree is clean and each of the 15 planted mutants (a UI caller of Lock.lock, a Connections on Lock, the lock or idle imported into the UI, a second Idle or a window in the host, Popups, ThemeIcons, WallpaperState, Battery, the notification server or the desktop in the security modules, ...) is found"
check python3 -I tests/security/security_process_scan.py --selftest "$root"
if [[ -x /usr/lib/qt6/bin/qmllint ]]; then
  desc="root: qmllint parses it (unknown-module warnings aside)"
  check bash -c '/usr/lib/qt6/bin/qmllint "$1" 2>&1 | grep -v -i -E "warning" | grep -qi "error" && exit 1; exit 0' _ "$qml"
else
  echo "NOTE: security unit root: qmllint not installed here (syntax NOT VERIFIED by this run)"
fi

desc="unit: loads the root by its path in the system tree (GF-115), no -c, with -n"
check grep -qx 'ExecStart=/usr/bin/qs -n -p /usr/share/grassfield/shell/security.qml' "$unit"
desc="unit: the same cleared environment as the UI's unit (both UnsetEnvironment= lines identical, the same Environment=)"
check bash -c '[[ "$(grep "^UnsetEnvironment=" "$1")" == "$(grep "^UnsetEnvironment=" "$2")" && "$(grep "^Environment=" "$1")" == "$(grep "^Environment=" "$2")" ]]' _ "$unit" "$ui"
desc="unit: Restart=always, RestartSec=1, a start limit a loop reaches (5 in 300 s), session-only, part of and requiring the session target"
check bash -c 'grep -qx "Restart=always" "$1" && grep -qx "RestartSec=1" "$1" && grep -qx "StartLimitIntervalSec=300" "$1" && grep -qx "StartLimitBurst=5" "$1" && grep -qx "ConditionEnvironment=GRASSFIELD_SESSION=1" "$1" && grep -qx "PartOf=graphical-session.target" "$1" && grep -qx "Requisite=graphical-session.target" "$1" && grep -qx "Slice=session.slice" "$1"' _ "$unit"
desc="unit: no NoNewPrivileges, ProtectSystem or sandbox that would break unix_chkpwd and polkit-agent-helper-1 (S2, S3), as the UI's unit"
check bash -c '! grep -qE "^(NoNewPrivileges|ProtectSystem|ProtectHome|PrivateUsers|SystemCallFilter|CapabilityBoundingSet)=" "$1"' _ "$unit"
desc="unit: OnFailure=omarchy-sleep-lock.service (S2: the sleep lock armed after every failure of the process that holds the inhibitor), and the UI's unit no longer arms it (its OnFailure= is the failure counter alone)"
check bash -c '[[ $(grep -c "^OnFailure=" "$1") == 1 ]] && grep -qx "OnFailure=omarchy-sleep-lock.service" "$1" && grep -qx "OnFailure=grassfield-shell-failed.service" "$2" && ! grep -q "omarchy-sleep-lock" <(grep "^OnFailure=" "$2")' _ "$unit" "$ui"
desc="unit: the lock keeps at least the headroom it had in the UI's unit (MemoryHigh and MemoryMax at least the UI unit's: never throttled before it is measured, the opus review of 77a0ceb3 MAJOR-2); CPUQuota as the UI unit's, at least a whole core"
check bash -c 'mb() { sed -nE "s/^$1=([0-9]+)([MG])$/\1 \2/p" "$2" | awk "{ print (\$2 == \"G\") ? \$1 * 1024 : \$1 }"; }
  high=$(mb MemoryHigh "$1") && max=$(mb MemoryMax "$1") && uihigh=$(mb MemoryHigh "$2") && uimax=$(mb MemoryMax "$2") && cpu=$(sed -nE "s/^CPUQuota=([0-9]+)%$/\1/p" "$1") &&
  [[ -n $high && -n $max && -n $uihigh && -n $uimax && -n $cpu ]] && ((high >= uihigh && max >= uimax && max > high && cpu >= 100)) &&
  [[ $cpu == "$(sed -nE "s/^CPUQuota=([0-9]+)%$/\1/p" "$2")" ]] && grep -q "157 MB" "$1" && grep -q "MemoryPeak" "$1"' _ "$unit" "$ui"
desc="autostart: started just before the shell, without waiting for it (--no-block), and the shell still starts if it failed"
check bash -c 'grep -q "systemctl --user start --no-block grassfield-security.service; systemctl --user start grassfield-shell.service" "$1"' _ config/hypr/grassfield/autostart.lua
desc="package: the unit is installed with the session units; the root ships with the shell tree; the helper from packaging/bin"
check bash -c 'grep -q "for unit in .*security" "$1" && grep -q "cp -a --no-preserve=ownership \"\$root/shell\" \"\$pkgdir/usr/share/grassfield/shell\"" "$1"' _ packaging/arch/PKGBUILD
desc="helper: read-only, calls the targets by the unit's path with Quickshell's option variables cleared (security state and heartbeat, lock state), never start, stop, kill or unlock"
check bash -c '[[ -x "$1" ]] && grep -q "unset QS_CONFIG_PATH QS_CONFIG_NAME QS_MANIFEST" "$1" && grep -q "call security state" "$1" && grep -q "call security heartbeat" "$1" && grep -q "call lock state" "$1" && ! grep -v "^#" "$1" | grep -qE "systemctl --user (start|stop|kill|restart|reset-failed)|unlock|kill "' _ "$helper"
desc="helper: works from a TTY: --any-display when WAYLAND_DISPLAY is not set (the instance is on another display connection), never inside the session"
check bash -c 'grep -q "\[ -n \"\${WAYLAND_DISPLAY:-}\" \] || display=\"--any-display\"" "$1" && [[ $(grep -c "qs ipc \$display -p" "$1") == 3 ]]' _ "$helper"
desc="IPC surface: the table lists target security with state and heartbeat as actions with their caller (tests/security/ipc_inventory.sh holds it to the code)"
check grep -qE '^\| security \| state, heartbeat \| action \|' docs/specs/security.md
desc="restart limits: the unit passes the lifetime model (a 10 s loop ends at its limit: 5 x (1 + 10) = 55 <= 300)"
check python3 -I tests/shell/unit_restart_limits.py "$unit"
exit "$fail"
