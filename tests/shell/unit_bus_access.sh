#!/usr/bin/env bash
# A user unit that talks to the session bus (notify-send, busctl, gdbus, D-Bus clients) must be able to reach
# /run/user/<uid>/bus: ProtectHome=yes (also true, 1, on) or tmpfs, TemporaryFileSystem= and InaccessiblePaths= over /run/user
# or /run hide that directory (systemd.exec(5): ProtectHome=yes makes /home, /root AND /run/user inaccessible), so the crash and
# low-battery notices never arrived. The right hardening is ProtectHome=read-only. Static: every packaged unit's ExecStart (and
# the script it runs) is read. The detector is proven by mutation below: each hiding setting, added to a copy of a bus user,
# must be caught.
set -euo pipefail
root=$(git -C "$(dirname "$0")" rev-parse --show-toplevel)
tmp=$(mktemp -d "${GRASSFIELD_TEST_TMP:-${TMPDIR:-/tmp}}/unit-bus.XXXXXX")
trap 'rm -rf "$tmp"' EXIT
fail=0
bus_users=0
check() { if "$@"; then echo "PASS: $desc"; else echo "FAIL: $desc"; fail=1; fi; }
# Compiled bus clients (no script to read): named here.
BINARY_BUS_UNITS="grassfield-menu-bridge.service grassfield-shell.service grassfield-secrets-handover.service grassfield-portal-settings.service"

# hides_bus FILE: true when the unit hides /run/user (and so the session bus socket).
hides_bus() {
  grep -qiE '^[[:space:]]*ProtectHome[[:space:]]*=[[:space:]]*(yes|true|1|on|tmpfs)[[:space:]]*$' "$1" ||
    grep -qiE '^[[:space:]]*(RootDirectory|RootImage|RootDirectoryStartOnly)[[:space:]]*=[[:space:]]*[^[:space:]]' "$1" ||
    grep -qiE '^[[:space:]]*(BindPaths|BindReadOnlyPaths)[[:space:]]*=.*:/run(/user)?(/[^[:space:]:]*)?(:|[[:space:]]|$)' "$1" ||
    grep -qiE '^[[:space:]]*(TemporaryFileSystem|InaccessiblePaths|InaccessibleDirectories)[[:space:]]*=[[:space:]]*([^#]*[[:space:]:+-])?/run(/user)?(/[^[:space:]:]*)?(:[^[:space:]]*)?([[:space:]]|$)' "$1"
}

export -f hides_bus
for unit in "$root"/packaging/systemd/*.service "$root"/packaging/systemd/*/*.conf; do
  [[ -f $unit ]] || continue
  name=${unit#"$root"/packaging/systemd/}
  exec_line=$(sed -n 's/^ExecStart=//p' "$unit" | head -n1)
  body=$exec_line
  prog=${exec_line%% *}
  case $prog in
    /usr/lib/grassfield/*) [[ -f $root/packaging/bin/${prog##*/} ]] && body+=$'\n'$(<"$root/packaging/bin/${prog##*/}") ;;
  esac
  is_bus=0
  grep -qE 'notify-send|busctl|gdbus|dbus-send|org\.freedesktop\.|Gio\.|QDBus' <<<"$body" && is_bus=1
  [[ " $BINARY_BUS_UNITS " == *" $(basename "$unit") "* ]] && is_bus=1
  if ((is_bus)); then
    bus_users=$((bus_users + 1))
    desc="$name talks to the session bus: nothing in it hides /run/user (ProtectHome yes/true/1/on/tmpfs, TemporaryFileSystem=, InaccessiblePaths=)"
    if hides_bus "$unit"; then echo "FAIL: $desc"; fail=1; else echo "PASS: $desc"; fi
  fi
done

desc="no packaged unit or drop-in hides /run/user at all (bus user or not), nor sets RootDirectory=/RootImage="
check bash -c 'for f in "$1"/packaging/systemd/*.service "$1"/packaging/systemd/*/*.conf; do [ -f "$f" ] || continue; hides_bus "$f" && { echo "hides: $f"; exit 1; }; done; exit 0' _ "$root"
desc="the scan is not vacuous: the crash, battery and migration notifiers, the menu bridge and the shell are among the bus users"
check test "$bus_users" -ge 5
for u in crash-watch battery-watch migrate-notify; do
  desc="grassfield-$u.service is recognised as a session bus user"
  check bash -c 'prog=$(sed -n "s/^ExecStart=//p" "$1/packaging/systemd/grassfield-$2.service" | head -n1); grep -qE "notify-send|busctl|gdbus" "$1/packaging/bin/${prog##*/}"' _ "$root" "$u"
done
desc="the crash and battery watchers use ProtectHome=read-only (as migrate-notify and automount do)"
check bash -c 'grep -qx "ProtectHome=read-only" "$1/packaging/systemd/grassfield-crash-watch.service" && grep -qx "ProtectHome=read-only" "$1/packaging/systemd/grassfield-battery-watch.service"' _ "$root"

# ---- mutation: the detector catches every way of hiding /run/user, and none of the safe settings ----
mutant() { # <line>: a copy of the crash watcher with the line added
  cp "$root/packaging/systemd/grassfield-crash-watch.service" "$tmp/m.service"
  sed -i '/^ProtectHome=/d' "$tmp/m.service"
  printf '%s\n' "$1" >>"$tmp/m.service"
}
for line in 'BindPaths=/var/empty:/run/user' 'BindReadOnlyPaths=/var/empty:/run/user/1000:norbind' 'InaccessiblePaths=+/run/user' 'RootDirectory=/var/lib/x' 'RootImage=/var/lib/x.img' 'ProtectHome=yes' 'ProtectHome=true' 'ProtectHome=1' 'ProtectHome=on' 'ProtectHome=tmpfs' 'ProtectHome = yes' 'ProtectHome=YES' \
  'TemporaryFileSystem=/run/user' 'TemporaryFileSystem=/run' 'TemporaryFileSystem=/run/user:ro' 'InaccessiblePaths=/run/user' 'InaccessiblePaths=-/run/user' \
  'InaccessiblePaths=/run' 'InaccessiblePaths=/proc /run/user/1000'; do
  mutant "$line"
  desc="mutation: '$line' on a bus user is caught"
  if hides_bus "$tmp/m.service"; then echo "PASS: $desc"; else echo "FAIL: $desc"; fail=1; fi
done
for line in 'ProtectHome=read-only' 'ProtectHome=no' 'ProtectHome=0' 'InaccessiblePaths=/proc' 'TemporaryFileSystem=/var'; do
  mutant "$line"
  desc="safe setting '$line' is not flagged"
  if hides_bus "$tmp/m.service"; then echo "FAIL: $desc"; fail=1; else echo "PASS: $desc"; fi
done
# The menu bridge (a compiled client) is covered: the same mutation on it is caught through the scan's own list.
cp "$root/packaging/systemd/grassfield-menu-bridge.service" "$tmp/b.service"
printf '%s\n' 'ProtectHome=yes' >>"$tmp/b.service" # the unit has no ProtectHome= line of its own (no user namespace)
desc="mutation: ProtectHome=yes on grassfield-menu-bridge.service is caught, and the bridge is in the bus list"
if hides_bus "$tmp/b.service" && [[ " $BINARY_BUS_UNITS " == *" grassfield-menu-bridge.service "* ]]; then echo "PASS: $desc"; else echo "FAIL: $desc"; fail=1; fi
# FINDINGS 3 (first real session): a unit with ProtectSystem=strict cannot create $XDG_RUNTIME_DIR/dconf, so a GSettings client in
# it needs %t/dconf writable (not the memory backend: udiskie's dialogs keep the user's real settings). A ReadWritePaths=-%t/dconf
# does not do it: the - drops the path when the directory is missing at start (at login qs and udiskie start in the same second),
# and the warnings came back in that session. RuntimeDirectory=dconf creates it before the sandbox is set up and keeps it
# writable; Preserve=yes because the shell and every GSettings client share it; 0700 as dconf creates it; and no unsandboxed
# '+' command to make it.
u=$root/packaging/systemd/grassfield-automount.service
automount_ok() { # FILE
  grep -qx 'RuntimeDirectory=dconf' "$1" && grep -qx 'RuntimeDirectoryPreserve=yes' "$1" && grep -qx 'RuntimeDirectoryMode=0700' "$1" &&
    grep -qx 'ProtectSystem=strict' "$1" && ! grep -qE '^ReadWritePaths=.*dconf' "$1" && ! grep -q GSETTINGS_BACKEND "$1" &&
    ! grep -qE '^ExecStartPre=[-@:+!]*\+' "$1"
}
desc="the removable-media unit keeps ProtectSystem=strict and has %t/dconf created and writable by RuntimeDirectory=dconf (kept after stop, 0700), with the real GSettings backend and no unsandboxed command"
if automount_ok "$u"; then echo "PASS: $desc"; else echo "FAIL: $desc"; fail=1; fi
# Mutants: each way of going back to the failing shape is caught.
amutant() { cp "$u" "$tmp/a.service"; sed -i "$1" "$tmp/a.service"; }
amutants=(
  's/^RuntimeDirectory=dconf$/RuntimeDirectory=other/|the runtime directory is not dconf'
  's/^RuntimeDirectory=dconf$/ReadWritePaths=-%t\/dconf/|the - form that drops a missing path'
  's/^RuntimeDirectoryPreserve=yes$//|the directory is removed when the unit stops'
  's/^RuntimeDirectoryMode=0700$/RuntimeDirectoryMode=0755/|the mode is not what dconf creates'
  's/^ProtectSystem=strict$/ProtectSystem=full/|the sandbox is weakened'
  '/^\[Service\]$/a ExecStartPre=+/usr/bin/mkdir -p %t/dconf|an unsandboxed mkdir is added'
  '/^\[Service\]$/a Environment=GSETTINGS_BACKEND=memory|the memory backend'
)
for spec in "${amutants[@]}"; do
  amutant "${spec%%|*}"
  desc="mutation (${spec#*|}) is caught"
  if automount_ok "$tmp/a.service"; then echo "FAIL: $desc"; fail=1; else echo "PASS: $desc"; fi
done
exit "$fail"
