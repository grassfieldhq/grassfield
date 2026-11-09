#!/usr/bin/env bash
# Nested (bare command, after `just nested-up`): ADR-0041 step 1, S3, the polkit agent and the secret sheets run in the
# security process. Checks, in this tree's nested session: the polkit and secrets targets answer on the security instance
# and not on the UI's (one agent, one prompter client); the security process logs what it hosts and one registration
# attempt per start (nested, the owner's agent holds the logind session: "not registered" is the expected answer, as before
# S3); a restart of the security process (`shell-run.sh --security`, as its unit's Restart=) makes a second attempt and
# leaves the UI alone. Read-only towards the owner's session (pid-selected instances of this tree only). PASS/FAIL lines.
set -u
root=$(git -C "$(dirname "$0")" rev-parse --show-toplevel)
cd "$root"
dev=$root/.dev
# shellcheck source=../../scripts/dev/pidfile.sh
. "$root/scripts/dev/pidfile.sh"
dev_nested_target "$dev" || exit 2
fail=0
pass() { echo "PASS: sheets process $*"; }
bad() { echo "FAIL: sheets process $*"; fail=1; }

ui=$(dev_live_pid "$dev/shell.pid") || { echo "FAIL: no nested UI"; exit 1; }
sec=$(dev_live_pid "$dev/security.pid") || { echo "FAIL: no nested security process"; exit 1; }
# call <pid> <target> <function>: the answer, and the exit status in rc.
call() { WAYLAND_DISPLAY=$DEV_NESTED_SOCK HYPRLAND_INSTANCE_SIGNATURE=$DEV_NESTED_SIG timeout 5 qs ipc --pid "$1" call "$2" "$3" 2>&1; }

for t in "polkit status" "secrets state"; do
  # shellcheck disable=SC2086
  out=$(call "$ui" $t); rc=$?
  ((rc != 0)) && ! grep -qE '^(registered|unregistered|off|connecting|ready|hello) ' <<<"$out " && pass "the UI instance does not answer '$t' (one agent and one prompter client, in the security process): rc $rc" || bad "the UI answered '$t': rc $rc, $out"
  # shellcheck disable=SC2086
  out=$(call "$sec" $t); rc=$?
  ((rc == 0)) && pass "the security instance answers '$t': $out" || bad "the security instance did not answer '$t': rc $rc, $out"
done
p=$(tests/visual/ipc.sh polkit status 2>&1)
[[ $p == registered || $p == unregistered ]] && pass "polkit status on the security instance: $p (nested: unregistered, the owner's agent holds the session)" || bad "polkit status: $p"
s=$(tests/visual/ipc.sh secrets state 2>&1)
[[ $s == "off - shown=0 held=0 waiting=0 linger=0" ]] && pass "secrets state on the security instance: $s (no test socket: off)" || bad "secrets state: $s"
grep -q "grassfield-security: ready (hosting lock idle polkit secrets" "$dev/security.log" && pass "the security process hosts lock idle polkit secrets" || bad "ready line: $(grep 'grassfield-security: ready' "$dev/security.log" | tail -1)"
grep -q "grassfield-polkit" "$dev/shell.log" && bad "the UI logged grassfield-polkit lines: $(grep -c grassfield-polkit "$dev/shell.log")" || pass "the UI log has no grassfield-polkit line"
attempts=$(grep -cE "grassfield-polkit: (authentication agent registered|not registered)" "$dev/security.log")
((attempts == 1)) && pass "one registration outcome in this security process's log ($(grep -E 'grassfield-polkit: (authentication agent registered|not registered)' "$dev/security.log" | sed 's/.*grassfield-polkit: //' | head -1))" || bad "registration outcomes: $attempts"
grep -q "the polkit agent and the secret sheets cannot" "$dev/security.log" && bad "the sheets failed to load: $(grep 'the polkit agent and the secret sheets' "$dev/security.log" | head -1)" || pass "the sheets loaded (no load failure logged)"

# The restart: a new security process, the same UI.
scripts/dev/shell-run.sh --security >/dev/null 2>&1 || bad "shell-run.sh --security failed"
sec2=""
for _ in $(seq 1 100); do
  sec2=$(dev_live_pid "$dev/security.pid") && [[ $sec2 != "$sec" ]] && grep -qE "grassfield-polkit: (authentication agent registered|not registered)" "$dev/security.log" && break
  sleep 0.1
done
[[ -n $sec2 && $sec2 != "$sec" ]] && pass "the security process restarted ($sec -> $sec2)" || bad "no new security process"
ui2=$(dev_live_pid "$dev/shell.pid") || ui2=""
[[ $ui2 == "$ui" ]] && pass "the UI was left alone ($ui)" || bad "the UI changed ($ui -> ${ui2:-none})"
grep -q "grassfield-security: ready (hosting lock idle polkit secrets" "$dev/security.log" && pass "the restarted process hosts the sheets again" || bad "restarted ready line missing"
attempts=$(grep -cE "grassfield-polkit: (authentication agent registered|not registered)" "$dev/security.log")
((attempts == 1)) && pass "the restarted process made one registration attempt" || bad "restarted registration outcomes: $attempts"
p=$(tests/visual/ipc.sh polkit status 2>&1)
[[ $p == registered || $p == unregistered ]] && pass "polkit status after the restart: $p" || bad "polkit status after the restart: $p"
exit "$fail"
