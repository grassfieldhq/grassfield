#!/usr/bin/env bash
# Gate L2, failure path against the REAL PAM service (owner decision D-10, 2026-10-23): in the NESTED session, three
# wrong passwords on the Grassfield lock screen. Run by the owner (or the integrator with the owner's go), bare, outside
# the sandbox; never against the owner's session.
#
# What it does, and the limits it enforces itself:
#   - restarts the nested shell with GRASSFIELD_DEV_ALLOW_PAM=1 (the dev opt-in: without it the lock never hands a
#     password to PAM) and checks the opt-in took effect (`lock devLockView` pamSuppressed false);
#   - locks, then for each of 3 attempts types a RANDOM wrong password (letters only, "gfwrong" + 16 random letters: never
#     the owner's password) and presses Return ONCE. Return is pressed at most 3 times per run (hard counter); a run is
#     refused when the previous one is less than 15 minutes old (faillock: deny=10 within 15 min, shared with sudo);
#   - after each attempt: "Incorrect password" shown, state back to `locked`, the field empty, failed attempts +1,
#     Hyprland reports LOCK, and nothing typed reached the probe window;
#   - finally restarts the nested shell WITHOUT the opt-in (PAM suppressed again; the session stays locked: finish with
#     scripts/dev/nested-down.sh) and audits the PAM attempts of the run (exactly 3).
# Exit status: 0 when every check passed; 2 when a precondition is missing; 4 when it stopped for safety.
set -uo pipefail

root=$(git -C "$(dirname "$0")" rev-parse --show-toplevel)
# GRASSFIELD_MIGRATED=1: the nested session runs the packaged form of the UI tree (scripts/dev/shell-run.sh --migrated,
# ADR-0056): both instances are addressed by the REAL path of the stamped tree (readlink -f .dev/migrated), as they were started.
ui_dir=$root/shell; sec_qml=$root/shell/security.qml
[[ ${GRASSFIELD_MIGRATED:-0} == 1 ]] && { ui_dir=$(readlink -f "$root/.dev/migrated")/shell; sec_qml=$ui_dir/security.qml; }
dev=$root/.dev
# shellcheck source=../../scripts/dev/pidfile.sh
. "$root/scripts/dev/pidfile.sh"
dev_require_host l2_wrong_password
dev_nested_target "$dev" || exit 2
sig=$DEV_NESTED_SIG
sock=$DEV_NESTED_SOCK
runs=$dev/l2-wrong-password.runs
typed=$dev/l2-typed.txt
status=0
returns=0
readonly MAX_RETURNS=3

nested() { env WAYLAND_DISPLAY="$sock" HYPRLAND_INSTANCE_SIGNATURE="$sig" "$@"; }
# The lock (and its PamContext) lives in the security process since ADR-0041 step 1, S2: its IPC, and its restarts with
# and without the PAM opt-in (`shell-run.sh --security`, the UI left alone).
ipc() { nested qs ipc -p "$sec_qml" call "$@" 2>/dev/null; }
pass() { echo "PASS $*"; }
fail() { echo "FAIL $*"; status=1; }
view() { ipc lock devLockView; }
field() { jq -r ".$1" <<<"$(view)" 2>/dev/null; }
compositor_locked() {
  nested hyprctl -j monitors 2>/dev/null | jq -e 'length > 0 and all(.[]; (.solitaryBlockedBy // []) | index("LOCK") != null)' >/dev/null
}

# Letters only, validated; never Return.
type_letters() { # <delay ms> <[a-z0-9] word>
  [[ $# -eq 2 && $1 =~ ^[0-9]{1,3}$ && $2 =~ ^[a-z0-9]+$ ]] || { echo "FATAL type_letters: refusing '$*'" >&2; stop_run "a refused probe"; }
  nested wtype -d "$1" "$2"
}
# The ONLY path that presses Return: at most MAX_RETURNS times per run.
press_return_once() {
  ((returns < MAX_RETURNS)) || { echo "FATAL: Return already pressed $returns times this run" >&2; stop_run "a 4th Return"; }
  returns=$((returns + 1))
  nested wtype -k Return
}
stop_run() { # <why>
  echo "STOP ($1): restarting the nested security process with PAM suppressed; the session stays locked" >&2
  env -u GRASSFIELD_DEV_ALLOW_PAM "$root/scripts/dev/shell-run.sh" --security >&2 || true
  exit 4
}

# --- rate limit: one run per 15 min (faillock window) ---
now=$(date +%s)
last=$(tail -n 1 "$runs" 2>/dev/null || echo 0)
[[ $last =~ ^[0-9]+$ ]] || last=0
if ((now - last < 900)); then
  echo "l2_wrong_password: the previous run was $((now - last)) s ago; wait until 15 min have passed (faillock window)" >&2
  exit 2
fi
[[ $(ipc lock status) == unlocked ]] || { echo "l2_wrong_password: the nested session must start unlocked (nested-down, nested-up)" >&2; exit 2; }

# --- PAM opt-in ---
. "$root/tests/security/pam_audit.sh"
GRASSFIELD_DEV_ALLOW_PAM=1 "$root/scripts/dev/shell-run.sh" --security >/dev/null
for _ in $(seq 1 40); do [[ $(field pamSuppressed) == false ]] && break; sleep 0.25; done
if [[ $(field pamSuppressed) != false ]]; then
  echo "l2_wrong_password: the opt-in did not take effect (lock devLockView: $(view)); nothing was typed" >&2
  env -u GRASSFIELD_DEV_ALLOW_PAM "$root/scripts/dev/shell-run.sh" --security >/dev/null
  exit 2
fi
pass "setup: the nested security process hands passwords to PAM (GRASSFIELD_DEV_ALLOW_PAM=1)"
read -r _ base_submits _ < <(pam_counts)
echo "$now" >>"$runs"

# --- probe window (keys must never reach it while locked) ---
: >"$typed"
"$root/scripts/dev/pointer.sh" output GF-REF abs 960 540 >/dev/null
nested setsid "$root/scripts/dev/isolated.sh" foot --app-id=gf-l2-probe -- sh -c 'stty raw -echo; exec cat >"$1"' sh "$typed" >/dev/null 2>&1 </dev/null &
dev_record_pid "$dev/l2-foot.pid" "$!"
sleep 2
"$root/scripts/dev/pointer.sh" output GF-REF abs 960 540 sleep 200 click >/dev/null
sleep 0.5
type_letters 15 control
sleep 0.7
grep -q control "$typed" && pass "setup: typing reaches the probe window while unlocked (control)" || fail "setup: control text did not reach the probe; leak checks are meaningless"

# --- lock ---
echo "lock lock -> $(ipc lock lock)"
for _ in $(seq 1 40); do [[ $(ipc lock status) == locked ]] && compositor_locked && break; sleep 0.25; done
[[ $(ipc lock status) == locked ]] && compositor_locked && pass "lock: locked, Hyprland reports LOCK" || stop_run "the session did not lock"
before=$(stat -c %s "$typed")

# --- three wrong attempts ---
for i in 1 2 3; do
  word=gfwrong$(tr -dc 'a-z' </dev/urandom | head -c 16)
  type_letters 10 "$word"
  sleep 0.5
  [[ $(field field) == filled ]] && pass "attempt $i: typed text is in the lock field" || fail "attempt $i: the field did not take the text ($(view))"
  press_return_once
  ok=""
  for _ in $(seq 1 120); do
    v=$(view)
    if [[ $(jq -r '.state' <<<"$v") == locked && $(jq -r '.failedAttempts' <<<"$v") == "$i" ]]; then ok=1; break; fi
    sleep 0.25
  done
  [[ -n $ok ]] || { fail "attempt $i: no failed attempt recorded within 30 s ($(view))"; continue; }
  v=$(view)
  [[ $(jq -r '.message' <<<"$v") == "Incorrect password" ]] && pass "attempt $i: \"Incorrect password\"" || fail "attempt $i: message '$(jq -r '.message' <<<"$v")'"
  [[ $(jq -r '.field' <<<"$v") == empty ]] && pass "attempt $i: the field is empty again" || fail "attempt $i: the field still holds text"
  [[ $(ipc lock status) == locked ]] && compositor_locked && pass "attempt $i: still locked (Hyprland LOCK)" || fail "attempt $i: not locked"
  [[ $(stat -c %s "$typed") == "$before" ]] && pass "attempt $i: nothing reached the probe window" || fail "attempt $i: keys reached the probe window"
done

# --- audit, then PAM suppressed again ---
read -r _ submits _ < <(pam_counts)
echo "PAM attempts this run: $((submits - base_submits)); Return pressed $returns times"
(((submits - base_submits) == 3)) && pass "audit: exactly 3 PAM attempts" || fail "audit: $((submits - base_submits)) PAM attempts (want 3)"
env -u GRASSFIELD_DEV_ALLOW_PAM "$root/scripts/dev/shell-run.sh" --security >/dev/null
for _ in $(seq 1 40); do [[ $(field pamSuppressed) == true ]] && break; sleep 0.25; done
[[ $(field pamSuppressed) == true && $(ipc lock status) == locked ]] && pass "end: security process restarted with PAM suppressed, still locked" || fail "end: $(view)"
dev_stop "$dev/l2-foot.pid" "L2 probe foot" >/dev/null || true
echo "The nested session stays locked: scripts/dev/nested-down.sh"
exit $status
