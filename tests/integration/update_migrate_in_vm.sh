#!/usr/bin/env bash
# Runs tests/integration/update_migrate.sh INSIDE a virtual machine, as its root, and shows what the VM's own kernel and
# journal say about its console while it ran. update_migrate.sh starts systemd as PID 1 in a container: on a machine with a live
# session that once ended the session (2026-11-11), so it runs only in a VM (docs/testing/README.md, "Running update_migrate.sh").
# `scripts/gates/vm-drill.sh update-migrate` ships the repository to the GF-010 VM and calls this script there.
#
#   tests/integration/update_migrate_in_vm.sh [REPO]     REPO defaults to the repository this script is in
# Exit: the test's (0 all PASS, 1 a FAIL), 2 refused (not in a VM, or not root).
set -uo pipefail
repo=$(cd "${1:-$(dirname "$0")/../..}" && pwd) || exit 2
vm=$(systemd-detect-virt --vm 2>/dev/null) || vm=''
[[ -n $vm && $vm != none ]] || { echo "refused: this script runs only inside a virtual machine (systemd-detect-virt --vm says none)" >&2; exit 2; }
[[ $(id -u) == 0 ]] || { echo "refused: run it as the VM's root" >&2; exit 2; }
out=/root/update-migrate-run
rm -rf "$out"
mkdir -p "$out"
# update_migrate.sh finds its repository through git: a shipped archive has none.
git -C "$repo" rev-parse --show-toplevel >/dev/null 2>&1 || git -C "$repo" init -q || exit 2
systemctl is-active docker >/dev/null || systemctl start docker
since=$(date '+%F %T')
snap() { # <file>: the console bindings and the foreground VT
  for f in /sys/class/vtconsole/vtcon*/name /sys/class/vtconsole/vtcon*/bind; do echo "$f: $(cat "$f" 2>/dev/null)"; done
  echo "active: $(cat /sys/class/tty/tty0/active 2>/dev/null)"
}
snap >"$out/console-before"
# The VM's own session is disposable: this is the one place that says so.
(cd "$repo" && GRASSFIELD_UPDATE_MIGRATE_VM_SESSION_OK=1 timeout 3000 ./tests/integration/update_migrate.sh) >"$out/run.log" 2>&1
rc=$?
sleep 3
snap >"$out/console-after"
journalctl -k --since "$since" --no-pager >"$out/kernel.log" 2>&1
journalctl --since "$since" --no-pager >"$out/journal.log" 2>&1
{
  echo "== VM: $vm; since $since"
  echo "== kernel log lines about the console, VTs, fbcon or tty"
  grep -iE 'fbcon|vtcon|console|vt[0-9]|tty[0-9]|Taking over' "$out/kernel.log" || echo "(none)"
  echo "== journal lines about vconsole, gettys, udev or SIGHUP"
  grep -iE 'systemd-vconsole|vconsole-setup|getty|systemd-udevd|SIGHUP|Taking over console' "$out/journal.log" || echo "(none)"
  echo "== console before / after"
  diff "$out/console-before" "$out/console-after" && echo "(identical)"
  echo "== update_migrate: $(grep -c '^PASS' "$out/run.log") PASS, $(grep -c '^FAIL' "$out/run.log") FAIL, exit $rc"
} | tee "$out/summary"
exit "$rc"
