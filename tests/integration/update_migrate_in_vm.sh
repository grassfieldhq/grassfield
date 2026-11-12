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
# update_migrate.sh refuses beside any graphical session, so the VM's display manager is stopped first (this script only runs in a
# VM) and started again afterwards.
dm=''
if systemctl is-active sddm >/dev/null 2>&1; then
  dm=sddm
  systemctl stop sddm
  for _ in $(seq 1 30); do
    loginctl list-sessions --no-legend 2>/dev/null | grep -q seat0 || break
    sleep 1
  done
fi
# stderr goes to err.log, the test's own lines to run.log. No `bash -x`: a trace would record proxy variables, credentials included.
(cd "$repo" && timeout 3000 ./tests/integration/update_migrate.sh) >"$out/run.log" 2>"$out/err.log"
rc=$?
if [[ -n $dm ]]; then systemctl reset-failed "$dm" 2>/dev/null; systemctl start "$dm" 2>/dev/null; fi
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
  if ((rc != 0)); then echo "== last lines of the run"; tail -n 15 "$out/run.log"; echo "== last lines of stderr"; tail -n 40 "$out/err.log"; fi
} | tee "$out/summary"
exit "$rc"
