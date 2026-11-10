#!/usr/bin/env bash
# Nested scenario (L1 only): the session lock survives soft reloads and crashes (R12, gate L1).
# Never targets the owner's session. Never types a password and never presses Return: the probe
# words typed with wtype land in the lock screen's field without being submitted (no PAM attempt).
#
# The lock lives in the security process (ADR-0041 step 1, S2: `qs -p shell/security.qml`, started beside the UI by
# scripts/dev/shell-run.sh, record .dev/security.pid, log .dev/security.log): every `lock` and `idle` IPC call below goes
# there, and the crash steps (l1, forged-crash, graceful-exit, foreign-restart) kill and restart THAT process
# (`shell-run.sh --security`, as its unit's Restart= would). The UI (`qs -p shell`, .dev/shell.pid) holds no lock: the
# ui-* steps crash or stop it and check that nothing about the lock changes.
#
# Usage: tests/security/reload_locked.sh [step...]   (default: every step, in this order)
#   setup           foot probe window in the nested session; typing reaches it while unlocked (control)
#   nowatch         touching a shell QML file reloads neither process (file watcher off)
#   ui-down-sleep   (S2) the UI stopped while unlocked: the before-sleep path (dev hook `idle devSleep`) still locks,
#                   nothing reaches foot; the UI is started again (it reads the session locked)
#   lock            lock through IPC (already locked after ui-down-sleep: `already-locked`)
#   ui-crash        (S2, ADR-0010's crash-injection test, DT-01) SIGSEGV to the UI while locked -> Hyprland keeps LOCK,
#                   the same security process keeps its lock (no lockdead screen: its client is alive and answers
#                   `locked`), nothing reaches foot; the restarted UI reads the session locked
#   marker-missing  remove the crash marker, soft reload  -> still locked, nothing reaches foot
#   marker-unlocked forge the marker to "unlocked", soft reload -> still locked, nothing reaches foot
#   l1              kill -9 the security process -> nothing reaches foot; restart it -> locked again (DT-21 for S2)
#   forged-crash    forge the marker to "unlocked", kill -9, restart -> the security process re-acquires the lock
#   graceful-exit   DT-21 (SEC-18): SIGTERM, then `qs kill --pid`, to the security process while locked -> Hyprland keeps
#                   LOCK, nothing reaches foot; the restarted security process is locked
#   foreign-takeover (b) a foreign locker takes over the live Grassfield lock -> still locked; it
#                   releases and exits -> Grassfield takes a fresh lock, nothing reaches foot
#   foreign-restart (a) foreign locker holding the lock + marker forged "unlocked" + shell restart ->
#                   the shell takes the lock over; once the restarted shell's start-up no longer holds its
#                   event loop (entrance logged, five prompt IPC answers in a row), the foreign locker
#                   releases -> fresh Grassfield lock requested within FOREIGN_MAX_MS (default 150). The hold
#                   seen (slowest IPC answer) must stay within HOLD_MAX_MS (default 3000; SKIP, not judged,
#                   when the load is above the core count)
#   lock-desync     (c) desync held on purpose (periodic check paused by the dev hook
#                   `lock devPauseOwnershipCheck`: Hyprland unlocked, shell "locked"), then `lock lock`
#                   -> a real lock, triggered by that request
#   sleep-desync    before-sleep path (dev hook `idle devSleep`): the sleep delay ends only on a
#                   confirmed lock; during a held desync, only after the fresh lock is acquired
#   relock-confirm  forced race (R12 review #3): one stale "unlocked" answer forged by the dev hook
#                   `lock devForgeUnlockedAnswer` while the session is really locked, then `lock lock`
#                   while keys are typed -> no relock (it waits for a fresh answer, which says locked),
#                   Hyprland reports LOCK throughout, nothing reaches foot; RELOCK_RUNS runs (default 12)
#   foreign-gap     forced race (R12 review #3): FOREIGN_RUNS (default 5) foreign takeovers of the live
#                   Grassfield lock, each released while keys are typed: prints the unlocked window and
#                   the keys that reached foot during it; fails when the fresh lock is requested more than
#                   GAP_MAX_MS (default 200) after the release (fixture and shell log times), when Hyprland
#                   does not report LOCK within 1.5 s, or when a key typed after the fresh lock reaches foot.
#                   The in-window key count needs foot to be the window Hyprland refocuses: run it right
#                   after `setup lock` (shell restarts in other steps can change that; the step says so)
#   probe-cost      CPU of the shell and the nested Hyprland with the 1 s check (plain lock) and the 100 ms
#                   check (a foreign locker holding the lock over Grassfield's); fails above +5 % CPU
#   cleanup         close the foot probe window and any foreign locker (run after the default sequence)
#   ui-down-idle    (S2, explicit only: about 75 s, on a fresh nested session before anything locks) the UI stopped while
#                   unlocked, lock.idleMinutes set to 1 in the dev config: the idle lock still fires (security process),
#                   nothing reaches foot; lock.idleMinutes back to 0 and the UI started again
#
# Foreign locker: tests/security/foreign_locker/ForeignLocker.qml (Quickshell WlSessionLock client,
# released over its IPC). Hyprland 0.56.2 (misc.allow_session_lock_restore = true) hands a live lock
# to the next client and tells the previous holder nothing; a release by either client unlocks the
# session. The foreign steps print "unlocked window": the time from the foreign release until Hyprland
# reports the session locked again (bounded by the shell's ownership check, every 100 ms while a takeover
# is suspected, and by its event loop being free, docs/specs/security.md).
#
# Requires scripts/dev/nested-up.sh (the shell runs with GRASSFIELD_DEV=1, which enables the
# `lock devReload` hook). Can start right after it: before any step, and after every shell restart,
# it waits at most READY_SECONDS (default 60) for GF-REF and a lock state from the shell
# (tests/security/nested_ready.sh); an empty answer is never a state, a timeout FAILs. The nested
# session stays locked afterwards: finish with nested-down.sh.
# Exit status: 0 when every requested step passed.
set -uo pipefail

root=$(git -C "$(dirname "$0")" rev-parse --show-toplevel)
# GRASSFIELD_MIGRATED=1: the nested session runs the packaged form of the UI tree (scripts/dev/shell-run.sh --migrated,
# ADR-0056): both instances are addressed by their path under .dev/migrated.
ui_dir=$root/shell; sec_qml=$root/shell/security.qml
[[ ${GRASSFIELD_MIGRATED:-0} == 1 ]] && { ui_dir=$root/.dev/migrated/shell; sec_qml=$ui_dir/security.qml; }
dev=$root/.dev
# shellcheck source=../../scripts/dev/pidfile.sh
. "$root/scripts/dev/pidfile.sh"
dev_require_host reload_locked
sig=$(cat "$dev/nested.instance" 2>/dev/null || true)
sock=$(cat "$dev/nested.wayland" 2>/dev/null || true)
main=$(cat "$dev/main.instance" 2>/dev/null || true)

[[ -n $sig && -n $sock ]] || { echo "reload_locked: no nested instance (run scripts/dev/nested-up.sh)" >&2; exit 2; }
[[ $sig != "$main" && $sig != "${HYPRLAND_INSTANCE_SIGNATURE:-}" ]] || { echo "reload_locked: refusing the main instance" >&2; exit 2; }
[[ $sock != "${WAYLAND_DISPLAY:-}" ]] || { echo "reload_locked: refusing the main Wayland socket" >&2; exit 2; }
[[ -n ${XDG_RUNTIME_DIR:-} ]] || { echo "reload_locked: XDG_RUNTIME_DIR unset" >&2; exit 2; }
# Wayland clients (foot, wtype, the foreign locker) must only reach the nested socket: it has to be
# the one Hyprland lists for the nested instance, and never the owner's (read-only `hyprctl instances`).
instances=$(hyprctl instances -j 2>/dev/null)
[[ -n $main && $(jq -r --arg s "$main" '.[] | select(.instance == $s) | .wl_socket' <<<"$instances") != "$sock" ]] \
  || { echo "reload_locked: refusing: no owner instance record, or its socket is the nested one" >&2; exit 2; }
[[ $(jq -r --arg s "$sig" '.[] | select(.instance == $s) | .wl_socket' <<<"$instances") == "$sock" ]] \
  || { echo "reload_locked: refusing: $sock is not the nested instance's socket" >&2; exit 2; }

marker=$XDG_RUNTIME_DIR/grassfield-lock-${sig//[^A-Za-z0-9_.-]/_}
# The process that holds the lock (ADR-0041 S2): its root (what its `qs ipc -p` names), log and record.
lock_root=$sec_qml
lock_log=$dev/security.log
typed=$dev/reload-typed.txt
foreign=$root/tests/security/foreign_locker/ForeignLocker.qml
status=0
# How long the shell may take to answer IPC after nested-up or a restart (tests/security/nested_ready.sh).
ready_secs=${READY_SECONDS:-60}
# shellcheck source=nested_ready.sh
. "$root/tests/security/nested_ready.sh"

nested() { env WAYLAND_DISPLAY="$sock" HYPRLAND_INSTANCE_SIGNATURE="$sig" "$@"; }
# Bounded: a stuck process answers nothing (empty, never a state) instead of hanging the run. The lock's and idle's targets
# are on the security instance.
ipc() { nested timeout -k 2 10 qs ipc -p "$lock_root" call "$@" 2>/dev/null; }
pass() { echo "PASS $*"; }
fail() { echo "FAIL $*"; status=1; }
# Captures are evidence only (no check reads them), so each has a deadline and a missing one is a note. grim waits for
# the output's next frame: GF-REF (headless) draws on its own, WAYLAND-1 only while the owner's compositor draws the
# nested window (an integrator run hung here before the l1 kill, as lock_privacy.sh once did for 25 min).
shot() {
  timeout -k 2 10 "$root/scripts/dev/shot.sh" "$1-gfref" GF-REF >/dev/null 2>&1 ||
    echo "NOTE no GF-REF capture for $1 within 10 s"
  timeout -k 2 10 "$root/scripts/dev/shot.sh" "$1-window" WAYLAND-1 >/dev/null 2>&1 ||
    echo "NOTE no WAYLAND-1 capture for $1 within 10 s (is the nested window shown on the owner's screen?)"
}

# Read-only compositor view of the lock: Hyprland lists LOCK in solitaryBlockedBy while a session lock
# is held, including one whose client died.
compositor_lock() {
  nested hyprctl -j monitors 2>/dev/null | jq -c '[.[] | {name, blockedBy: (.solitaryBlockedBy // [])}]'
}

wait_status() { # <expected> <seconds>
  local want=$1 tries=$(($2 * 4)) got=""
  for _ in $(seq 1 "$tries"); do
    got=$(ipc lock status)
    [[ $got == "$want" ]] && { echo "$got"; return 0; }
    sleep 0.25
  done
  echo "${got:-no-answer}"
  return 1
}

# After shell-run.sh: the restarted shell answers IPC only once its configuration has loaded (5-9 s in the integrator's
# run of 2026-11-04, more on a loaded machine), and its empty answer until then is no lock state. Waits for a lock state
# (nested_ready, at most $ready_secs), then for "locked" within <seconds>; prints the last status or why the shell is not
# ready. Hyprland keeps the session locked meanwhile (the dead client's or the foreign locker's lock): the callers check
# that separately (compositor_lock, no_leak).
restarted_status() { # <seconds>
  nested_ready "$sig" "$sock" "$lock_root" "$ready_secs" || { echo "not ready: $nested_ready_why"; return 1; }
  wait_status locked "$1"
}

# SAFETY (R12 review #3 MAJOR): every probe this script types is letters only. A Return/newline/Enter in a probe that
# reaches the lock's password field submits it to PAM and counts a faillock failure against the owner's real account.
# type_letters is the ONLY typing path; it refuses anything but [a-z0-9] (letters and digits never submit; a step name
# may carry a digit, e.g. "deadl1"), and the shell suppresses PAM in dev anyway (GRASSFIELD_DEV without
# GRASSFIELD_DEV_ALLOW_PAM). press_key only allows keys that never submit (Escape).
type_letters() { # <delay ms> <word>: exactly two arguments, both validated; no option ever passes through
  [[ $# -eq 2 && $1 =~ ^[0-9]{1,3}$ && $2 =~ ^[a-z0-9]+$ ]] \
    || { echo "FATAL type_letters: refusing arguments '$*' (want: <delay ms> <[a-z0-9] word>)" >&2; abort_run "a refused probe"; }
  nested wtype -d "$1" "$2"
}
press_key() { # Escape: exactly one argument, and only Escape
  [[ $# -eq 1 && $1 == Escape ]] || { echo "FATAL press_key: refusing '$*' (only Escape is allowed; it never submits)" >&2; abort_run "a disallowed key"; }
  nested wtype -k Escape
}
# Types a letters-only word in the background (sets $typer). Validated synchronously first, so a bad probe aborts before
# anything is typed.
bg_type() { # <word>: exactly one [a-z0-9] argument
  [[ $# -eq 1 && $1 =~ ^[a-z0-9]+$ ]] || { echo "FATAL bg_type: refusing arguments '$*' (want one [a-z0-9] word)" >&2; abort_run "a refused probe"; }
  nested wtype -d 4 "$1" &
  typer=$!
}

# All PAM attempts this run could ever cause, over EVERY instance log of this tree's shell (tests/security/pam_audit.sh:
# restarts overwrite .dev/shell.log, so the per-instance Quickshell logs are the record). "(submit)" is a real PAM call
# (must never happen); "PAM submit suppressed" means a key reached the lock field (the shell blocked PAM; still a
# defect). Counted against a baseline taken when the run starts, so older attempts in exited instances are not re-counted.
# shellcheck source=pam_audit.sh
. "$root/tests/security/pam_audit.sh"
read -r pam_base_instances pam_base_submits pam_base_suppressed < <(pam_counts)
pam_new() { # "<new submits> <new suppressed>" since the run started
  local n s x
  read -r n s x < <(pam_counts)
  echo "$((s - pam_base_submits)) $((x - pam_base_suppressed))"
}

# Stop the whole run the moment a probe could have touched PAM: stop the nested session and exit non-zero, loudly.
abort_run() { # <why>
  local s x
  read -r s x < <(pam_new)
  echo "" >&2
  echo "ABORT ($1): new PAM submits=$s, new suppressed submits=$x since the run started. Stopping the nested session." >&2
  "$root/scripts/dev/nested-down.sh" >&2 2>&1 || true
  exit 4
}

# Called before the loop and after every step: fail closed on the first sign a key reached the lock field.
assert_no_pam() { # <when>
  local s x
  read -r s x < <(pam_new)
  if ((s > 0 || x > 0)); then
    abort_run "$1"
  fi
}

# Types a probe word (letters only, never Return) and checks that foot did not receive it.
no_leak() { # <word> <step>
  type_letters 15 "$1"
  sleep 0.7
  if grep -q "$1" "$typed" 2>/dev/null; then fail "$2: typed text reached the foot window ($1)"; else pass "$2: nothing reached the foot window"; fi
}

# Only a record that still matches its process (scripts/dev/pidfile.sh): a stale PID may name an owner process. The lock's
# holder is the security process (ADR-0041 S2); the UI is the shell.
lock_pid() { dev_live_pid "$dev/security.pid"; }
ui_pid() { dev_live_pid "$dev/shell.pid"; }
# The security process again, as its unit's Restart= would bring it back (the UI is left alone).
restart_lock() { "$root/scripts/dev/shell-run.sh" --security; }

step_setup() {
  : >"$typed"
  # New windows open on the monitor under the pointer: put it on the deterministic GF-REF output.
  "$root/scripts/dev/pointer.sh" output GF-REF abs 960 540 >/dev/null
  # Raw mode: every key reaches cat at once, no Return needed. foot's own messages (never the typed text, which goes
  # through its terminal to cat) go to .dev/reload-foot.log, so that a window that does not appear says why.
  env WAYLAND_DISPLAY="$sock" HYPRLAND_INSTANCE_SIGNATURE="$sig" \
    setsid "$root/scripts/dev/isolated.sh" foot --app-id=gf-reload-probe -- sh -c 'stty raw -echo; exec cat >"$1"' sh "$typed" >"$dev/reload-foot.log" 2>&1 </dev/null &
  dev_record_pid "$dev/reload-foot.pid" "$!"
  local geo=""
  for _ in $(seq 1 80); do
    geo=$(nested timeout -k 2 5 hyprctl -j clients 2>/dev/null | jq -r '.[] | select(.class == "gf-reload-probe") | "\(.monitor) \(.at[0]) \(.at[1]) \(.size[0]) \(.size[1])"')
    [[ -n $geo ]] && break
    sleep 0.25
  done
  if [[ -z $geo ]]; then
    if dev_live_pid "$dev/reload-foot.pid" >/dev/null; then
      fail "setup: the foot probe window did not appear within 20 s (foot is running; see .dev/reload-foot.log)"
    else
      fail "setup: the foot probe window did not appear: foot exited ('$(tail -n 1 "$dev/reload-foot.log" 2>/dev/null)'; see .dev/reload-foot.log)"
    fi
    return
  fi
  local mon x y w h name mx my
  read -r mon x y w h <<<"$geo"
  read -r name mx my < <(nested hyprctl -j monitors | jq -r --argjson m "$mon" '.[] | select(.id == $m) | "\(.name) \(.x) \(.y)"')
  # Focus it with a click (focus follows the pointer; no state-changing hyprctl).
  "$root/scripts/dev/pointer.sh" output "$name" abs $((x - mx + w / 2)) $((y - my + h / 2)) sleep 200 click >/dev/null
  sleep 0.5
  type_letters 15 control
  sleep 0.7
  if grep -q control "$typed"; then pass "setup: typing reaches the foot window on $name while unlocked (control)"; else fail "setup: control text did not reach foot; leak checks are meaningless"; fi
}

step_nowatch() {
  local before after sbefore safter
  before=$(grep -c "Reloading configuration" "$dev/shell.log" 2>/dev/null)
  sbefore=$(grep -c "Reloading configuration" "$lock_log" 2>/dev/null)
  touch "$root/shell/security/lock/LockView.qml" "$root/shell/security.qml"
  sleep 3
  after=$(grep -c "Reloading configuration" "$dev/shell.log" 2>/dev/null)
  safter=$(grep -c "Reloading configuration" "$lock_log" 2>/dev/null)
  if [[ $before == "$after" ]]; then pass "nowatch: a touched QML file did not reload the shell"; else fail "nowatch: the shell reloaded after a file change"; fi
  if [[ $sbefore == "$safter" ]]; then pass "nowatch: a touched QML file did not reload the security process"; else fail "nowatch: the security process reloaded after a file change"; fi
}

# The UI's own reading of the lock, from its log: the start line names LockClient's state ("lock locked") and every change
# of what it reads is logged ("the session reads locked").
ui_reads_locked() { # <seconds>: 0 once the restarted UI logged its start with the lock state "locked"
  local deadline=$((SECONDS + $1)) line
  while ((SECONDS < deadline)); do
    line=$(grep -m1 "grassfield-shell: started" "$dev/shell.log" 2>/dev/null)
    if [[ -n $line ]]; then
      [[ $line == *" lock locked "* ]] && return 0
      grep -q "grassfield: the session reads locked" "$dev/shell.log" 2>/dev/null && return 0
    fi
    sleep 0.5
  done
  return 1
}

# ADR-0041 S2, ADR-0010's crash-injection test (DT-01): a crash of the UI while locked changes nothing about the lock.
step_ui_crash() {
  local s pid lockpid
  s=$(wait_status locked 5) || { fail "ui-crash: precondition: status $s (run the lock step first)"; return; }
  pid=$(ui_pid) || { fail "ui-crash: no live UI record (.dev/shell.pid)"; return; }
  lockpid=$(lock_pid) || { fail "ui-crash: no live security process record (.dev/security.pid)"; return; }
  dev_may_signal "$pid" || { fail "ui-crash: refusing to signal PID $pid"; return; }
  [[ $pid != "$lockpid" ]] || { fail "ui-crash: the UI's record names the security process (PID $pid)"; return; }
  # The UI writes no core (shell-run.sh: ulimit -c 0, as the units' LimitCORE=0). The integrator's nested run of 122f8d67,
  # before that limit, saw the SIGSEGV'd UI still alive after 5 s: the kernel was writing its core (hundreds of MB) to
  # systemd-coredump, and a process is gone only once its dump is written. Its Process children (inotifywait, gio monitor)
  # were listed as if they kept it alive; they did not.
  local core_limit
  core_limit=$(awk '/^Max core file size/ {print $5 " " $6}' "/proc/$pid/limits" 2>/dev/null)
  [[ $core_limit == "0 0" ]] && pass "ui-crash: the UI runs with no core file (soft and hard limit 0)" \
    || fail "ui-crash: the UI's core file limit is '${core_limit:-unknown}' (want 0 0: scripts/dev/shell-run.sh ulimit -c 0)"
  local t0=$SECONDS dumping=0
  kill -SEGV "$pid"
  for _ in $(seq 1 50); do kill -0 "$pid" 2>/dev/null || break; sleep 0.1; done
  # A core being written: wait for the dump to end (at most 60 s more), and say so.
  while kill -0 "$pid" 2>/dev/null && grep -qx $'CoreDumping:\t1' "/proc/$pid/status" 2>/dev/null && ((SECONDS - t0 < 65)); do
    dumping=1
    sleep 0.5
  done
  # Quickshell's crash handler would keep the crashed process alive under a relaunched child (QS_DISABLE_CRASH_HANDLER=1 in
  # the units and in scripts/dev/shell-run.sh turns it off): named here if it ever comes back.
  if kill -0 "$pid" 2>/dev/null; then
    fail "ui-crash: the UI did not exit after SIGSEGV ($((SECONDS - t0)) s; state $(awk '/^State:/ {print $2 $3}' "/proc/$pid/status" 2>/dev/null); children: $(pgrep -P "$pid" -a 2>/dev/null | tr '\n' ';' | cut -c1-200); QS_DISABLE_CRASH_HANDLER in its environment: $(tr '\0' '\n' <"/proc/$pid/environ" 2>/dev/null | grep -c '^QS_DISABLE_CRASH_HANDLER=1$'))"
    # The later steps need a UI: this one is ended and replaced, so that one failure does not run the rest without it.
    kill -KILL "$pid" 2>/dev/null
    for _ in $(seq 1 50); do kill -0 "$pid" 2>/dev/null || break; sleep 0.1; done
    "$root/scripts/dev/shell-run.sh"
    return
  fi
  if ((dumping)); then
    fail "ui-crash: the UI ended on SIGSEGV only after $((SECONDS - t0)) s in its core dump (the kernel hands the core to systemd-coredump whatever the limit; with a limit of 0 it must end at once)"
  else
    pass "ui-crash: the UI ended on SIGSEGV within $((SECONDS - t0)) s (no crash handler kept it alive, no core written)"
  fi
  sleep 0.5
  echo "compositor after the UI's crash: $(compositor_lock)"
  if compositor_locked; then pass "ui-crash: Hyprland still reports LOCK on every monitor"; else fail "ui-crash: the session is UNLOCKED after a crash of the UI"; fi
  if [[ $(lock_pid) == "$lockpid" ]]; then pass "ui-crash: the security process is untouched (PID $lockpid)"; else fail "ui-crash: the security process changed or stopped"; fi
  s=$(ipc lock status)
  if [[ $s == locked ]]; then pass "ui-crash: the lock's client is alive and holds its lock (status locked: no lockdead screen)"; else fail "ui-crash: status '$s' after a crash of the UI"; fi
  shot ui-crash-dead
  no_leak uicrash "ui-crash (UI gone)"
  "$root/scripts/dev/shell-run.sh"
  if ui_reads_locked 60; then pass "ui-crash: the restarted UI reads the session locked"; else fail "ui-crash: the restarted UI did not log the session locked within 60 s (.dev/shell.log)"; fi
  if [[ $(lock_pid) == "$lockpid" ]]; then pass "ui-crash: the UI's restart left the security process alone"; else fail "ui-crash: the UI's restart restarted the security process"; fi
  s=$(wait_status locked 3) && pass "ui-crash: still locked after the UI's restart" || fail "ui-crash: status $s after the UI's restart"
  shot ui-crash-restarted
  no_leak uiback "ui-crash (UI restarted)"
}

# Stops the UI (SIGKILL: no clean exit) and waits until it is gone. 0 when it is.
stop_ui() { # <step>
  local pid
  pid=$(ui_pid) || { fail "$1: no live UI record (.dev/shell.pid)"; return 1; }
  dev_may_signal "$pid" || { fail "$1: refusing to signal PID $pid"; return 1; }
  kill -9 "$pid"
  for _ in $(seq 1 50); do kill -0 "$pid" 2>/dev/null || break; sleep 0.1; done
  if kill -0 "$pid" 2>/dev/null; then fail "$1: the UI did not exit"; return 1; fi
  return 0
}

# ADR-0041 S2: with the UI down and the session unlocked, a sleep still locks first (the inhibitor's before-sleep path,
# through the dev hook: the dev session holds no logind inhibitor).
step_ui_down_sleep() {
  local s
  s=$(ipc lock status)
  [[ $s == unlocked ]] || { fail "ui-down-sleep: precondition: status '$s' (run it on a fresh nested session, before lock)"; return; }
  stop_ui ui-down-sleep || return
  echo "idle devSleep before -> $(ipc idle devSleep before)"
  if s=$(wait_status locked 10); then pass "ui-down-sleep: the before-sleep path locked with the UI down (status $s)"; else fail "ui-down-sleep: status $s with the UI down"; fi
  if compositor_locked; then pass "ui-down-sleep: Hyprland reports LOCK"; else fail "ui-down-sleep: Hyprland does not report LOCK"; fi
  echo "idle devSleep after -> $(ipc idle devSleep after)"
  no_leak uidownsleep "ui-down-sleep (UI down)"
  "$root/scripts/dev/shell-run.sh"
  if ui_reads_locked 60; then pass "ui-down-sleep: the started UI reads the session locked"; else fail "ui-down-sleep: the started UI did not log the session locked within 60 s"; fi
}

# ADR-0041 S2: with the UI down and the session unlocked, the idle lock still fires (lock.idleMinutes 1: the dim at 50 s,
# the lock at 60 s without input). Explicit only (about 75 s).
step_ui_down_idle() {
  local s cfg=$dev/config/grassfield.json
  s=$(ipc lock status)
  [[ $s == unlocked ]] || { fail "ui-down-idle: precondition: status '$s' (run it on a fresh nested session, before anything locks)"; return; }
  [[ -s $cfg ]] || { fail "ui-down-idle: no dev config ($cfg)"; return; }
  stop_ui ui-down-idle || return
  jq '.lock.idleMinutes = 1' "$cfg" >"$cfg.new" && mv "$cfg.new" "$cfg"
  echo "lock.idleMinutes: $(jq '.lock.idleMinutes' "$cfg") (the security process's settings watch picks it up)"
  if s=$(wait_status locked 80); then pass "ui-down-idle: the idle lock fired with the UI down (status $s)"; else fail "ui-down-idle: status $s 80 s after lock.idleMinutes 1 with the UI down"; fi
  jq '.lock.idleMinutes = 0' "$cfg" >"$cfg.new" && mv "$cfg.new" "$cfg"
  no_leak uidownidle "ui-down-idle (UI down)"
  "$root/scripts/dev/shell-run.sh"
}

step_lock() {
  echo "lock lock -> $(ipc lock lock)"
  local s
  if s=$(wait_status locked 10); then pass "lock: status $s"; else fail "lock: status $s"; fi
  echo "marker: $(cat "$marker" 2>/dev/null || echo '<missing>')"
  echo "compositor: $(compositor_lock)"
  shot reload-locked
}

reload_case() { # <name> <marker action>
  local name=$1 s
  case $2 in
    remove) rm -f "$marker" ;;
    unlocked) printf 'unlocked\n' >"$marker" ;;
  esac
  echo "marker before reload: $(cat "$marker" 2>/dev/null || echo '<missing>')"
  echo "lock devReload -> $(ipc lock devReload)"
  sleep 3
  if s=$(wait_status locked 5); then pass "$name: status after reload $s"; else fail "$name: status after reload $s"; fi
  echo "marker after reload: $(cat "$marker" 2>/dev/null || echo '<missing>')"
  echo "compositor: $(compositor_lock)"
  shot "reload-$name"
  no_leak "leak${name//-/}" "$name"
}

step_marker_missing() { reload_case marker-missing remove; }
step_marker_unlocked() { reload_case marker-unlocked unlocked; }

crash_and_restart() { # <name> <wait seconds>
  local name=$1 pid s
  pid=$(lock_pid)
  [[ -n $pid ]] && kill -0 "$pid" 2>/dev/null || { fail "$name: security process not running"; return; }
  dev_may_signal "$pid" || { fail "$name: refusing to signal PID $pid"; return; }
  kill -9 "$pid"
  sleep 1.5
  echo "compositor after kill -9: $(compositor_lock)"
  if compositor_locked; then pass "$name: Hyprland keeps LOCK while the security process is dead"; else fail "$name: the session is UNLOCKED while the security process is dead"; fi
  shot "$name-dead"
  no_leak "dead${name//-/}" "$name (security process dead)"
  restart_lock
  if s=$(restarted_status "$2"); then pass "$name: restarted security process status $s"; else fail "$name: restarted security process status $s"; fi
  shot "$name-restarted"
  no_leak "back${name//-/}" "$name (restarted)"
}

step_l1() { crash_and_restart l1 10; }

# DT-21 / SEC-18 (GF-029): a GRACEFUL exit while locked must leave the session locked. (a) SIGTERM (Quickshell has no
# SIGTERM handler: the process ends at once); (b) `qs kill --pid` (IPC kill: the engine is torn down and WlSessionLock's
# lock object sends ext_session_lock_v1.destroy, never unlock_and_destroy; Hyprland 0.56.2 then keeps the session
# locked). After each: Hyprland lists LOCK on every monitor, nothing typed reaches foot, the restarted shell is locked.
graceful_case() { # <term|qskill>
  local how=$1 pid s
  s=$(wait_status locked 5) || { fail "graceful-exit ($how): precondition: status $s (run the lock step first)"; return; }
  pid=$(lock_pid)
  [[ -n $pid ]] && kill -0 "$pid" 2>/dev/null || { fail "graceful-exit ($how): security process not running"; return; }
  dev_may_signal "$pid" || { fail "graceful-exit ($how): refusing to signal PID $pid"; return; }
  case $how in
    term) kill -TERM "$pid" ;;
    qskill) echo "qs kill -> $(qs kill --pid "$pid" 2>&1 | tr '\n' ' ')" ;;
  esac
  for _ in $(seq 1 50); do kill -0 "$pid" 2>/dev/null || break; sleep 0.1; done
  if kill -0 "$pid" 2>/dev/null; then fail "graceful-exit ($how): the security process did not exit within 5 s"; return; fi
  sleep 0.5
  echo "compositor after the $how exit: $(compositor_lock)"
  if compositor_locked; then pass "graceful-exit ($how): Hyprland still reports LOCK on every monitor"; else fail "graceful-exit ($how): the session is UNLOCKED after a graceful exit (SEC-18: re-rate MEDIUM)"; fi
  shot "graceful-$how-dead"
  no_leak "graceful${how}" "graceful-exit ($how, security process gone)"
  restart_lock
  if s=$(restarted_status 15); then pass "graceful-exit ($how): restarted security process status $s"; else fail "graceful-exit ($how): restarted security process status $s"; fi
  no_leak "gracefulback${how}" "graceful-exit ($how, restarted)"
}

step_graceful_exit() {
  graceful_case term
  graceful_case qskill
}

step_forged_crash() {
  printf 'unlocked\n' >"$marker"
  echo "marker forged: $(cat "$marker")"
  crash_and_restart forged-crash 15
}

# --- Foreign locker (R12 re-review: a lock taken over and released by another client) ---

foreign_ipc() { nested timeout -k 2 10 qs ipc -p "$foreign" call foreign "$@" 2>/dev/null; }

# All monitors list LOCK (read-only hyprctl query of the nested instance).
compositor_locked() {
  nested hyprctl -j monitors 2>/dev/null | jq -e 'length > 0 and all(.[]; (.solitaryBlockedBy // []) | index("LOCK") != null)' >/dev/null
}

foreign_start() { # <step>: start the foreign locker; it takes the session lock over
  # Nested socket and instance only (checked at the top); the fixture refuses anything else itself.
  env WAYLAND_DISPLAY="$sock" HYPRLAND_INSTANCE_SIGNATURE="$sig" GRASSFIELD_FOREIGN_LOCKER=1 \
    setsid "$root/tests/security/foreign_locker/run.sh" --no-color >"$dev/foreign-locker.log" 2>&1 </dev/null &
  dev_record_pid "$dev/foreign-locker.pid" "$!"
  local got=""
  for _ in $(seq 1 40); do
    got=$(foreign_ipc status)
    [[ $got == "locked secure" ]] && break
    sleep 0.25
  done
  if [[ $got == "locked secure" ]]; then pass "$1: the foreign locker holds the session lock"; else fail "$1: foreign locker status '${got:-no-answer}'"; fi
}

foreign_wait_exit() { # <step>: the foreign locker exits after its release
  for _ in $(seq 1 20); do dev_live_pid "$dev/foreign-locker.pid" >/dev/null || break; sleep 0.1; done
  if dev_live_pid "$dev/foreign-locker.pid" >/dev/null; then fail "$1: the foreign locker did not exit"; else pass "$1: the foreign locker exited"; rm -f "$dev/foreign-locker.pid" "$dev/foreign-locker.pid.start"; fi
}

# Releases the foreign lock, then measures how long Hyprland reports the session unlocked before the
# shell's fresh lock: prints "unlocked window". Fails if the session is not locked by Grassfield
# (status locked + LOCK on every monitor) within 3 s, or if the foreign locker does not exit.
# Release -> fresh lock request (ms) from the fixture's release epoch and the first "taking a fresh lock" in the shell
# log after line <from>; empty when either is missing.
relock_reaction_ms() { # <shell.log line count before the release>
  local released relocked
  released=$(grep -o "unlocking on request at [0-9]*" "$dev/foreign-locker.log" | tail -n 1 | grep -o "[0-9]*$")
  relocked=$(tail -n +"$(($1 + 1))" "$lock_log" | grep -m1 "taking a fresh lock" | cut -c1-23)
  [[ -n $released && -n $relocked ]] && echo $(($(date -d "$relocked" +%s%3N) - released))
}

# The shell is in the suspected state now (100 ms check): its last suspicion line says so.
suspected_now() { grep -E "takeover suspected \(|no takeover suspected" "$lock_log" | tail -n 1 | grep -q "takeover suspected ("; }

last_react=""
foreign_release_and_wait() { # <step>
  local t0 now first="" s from
  from=$(wc -l <"$lock_log")
  t0=${EPOCHREALTIME/./}
  echo "foreign unlock -> $(foreign_ipc unlock)"
  for _ in $(seq 1 60); do
    if compositor_locked; then
      now=${EPOCHREALTIME/./}
      first=$(((now - t0) / 1000))
      break
    fi
    sleep 0.05
  done
  if [[ -n $first ]]; then echo "unlocked window: <= ${first} ms (foreign release -> Hyprland reports LOCK again)"; fi
  # Hyprland lists LOCK as soon as a session lock exists; the shell's status becomes "locked" only on Hyprland's `locked`
  # event, sent once every enabled monitor has drawn a frame of its lock surface (WlSessionLock.secure, Lock.qml
  # onSecureStateChanged). In the nested session WAYLAND-1 draws only when the parent presents the nested window, so the
  # confirmation can come late (the integrator's run of c80c55b3: "locking" 3 s after a release whose LOCK came back in
  # 221 ms, with no WAYLAND-1 capture all run long). Meanwhile the session is locked (LOCK) and the UI reads "locking" as
  # locked (LockState.uiLocked, uiLockConfirmed). So: LOCK back within 3 s (above), the confirmed "locked" within 10 s,
  # and the time to the confirmation printed.
  if [[ -n $first ]] && s=$(wait_status locked 10); then pass "$1: locked again by Grassfield after the foreign release (status $s)"; else fail "$1: not re-locked after the foreign release (status ${s:-?} after 10 s, compositor $(compositor_lock); a 'locking' with LOCK on every monitor waits for a lock frame on each: is the nested window shown?)"; fi
  confirm_time "$1" "$from"
  foreign_wait_exit "$1"
  echo "compositor: $(compositor_lock)"
  grep "grassfield-lock: the session is unlocked although" "$lock_log" | tail -n 1
  last_react=$(relock_reaction_ms "$from")
  echo "$1: foreign release -> fresh lock request ${last_react:-?} ms (fixture and shell logs)"
}

# Fails when the last foreign release took more than <max> ms to get a fresh lock (the 100 ms check must catch it).
assert_react() { # <step> <max ms>
  if [[ -n $last_react ]] && ((last_react <= $2)); then pass "$1: fresh lock requested $last_react ms after the foreign release (<= $2)"; else fail "$1: fresh lock requested ${last_react:-?} ms after the foreign release (> $2 ms or not measured)"; fi
}

step_foreign_takeover() {
  local s
  s=$(ipc lock status)
  [[ $s == locked ]] || { fail "foreign-takeover: precondition: status $s (run the lock step first)"; return; }
  foreign_start foreign-takeover
  if s=$(wait_status locked 1); then pass "foreign-takeover: status while the foreign locker holds the lock: $s"; else fail "foreign-takeover: status $s"; fi
  if compositor_locked; then pass "foreign-takeover: Hyprland reports the session locked"; else fail "foreign-takeover: compositor $(compositor_lock)"; fi
  shot foreign-takeover-held
  no_leak heldforeign "foreign-takeover (foreign locker holds the lock)"
  foreign_release_and_wait foreign-takeover
  assert_react foreign-takeover "${FOREIGN_MAX_MS:-150}"
  shot foreign-takeover-relocked
  no_leak afterforeign "foreign-takeover (after the foreign release)"
}

# Every lock check (the 100 ms ownership check, the keyboard-focus event, monitor answers) runs on the shell's event loop,
# and a restarted shell's start-up holds that loop: in the integrator's run of 2026-11-04 each locked restart logged
# nothing for 1.2-2.1 s after its entrance (shell/services/Entrance.qml: the menu bar, the Dock and the icons appear), and
# a foreign release ~1.5 s after the takeover fell inside it: the fresh lock came 1350 ms (1616 ms on main) after the
# release, the 100 ms check in force throughout. Since ADR-0041 S2 the lock's process is the security process, whose start
# draws no desktop: the wait is for its "grassfield-security: ready" line (shell-run.sh --security rewrites
# .dev/security.log) instead of the UI's entrance, then until it answers `lock status` within 500 ms (qs
# client start included, about 0.1 s) five times in a row: its IPC is served on that same loop, so a held loop answers
# late and restarts the count. Prints "<ms from this shell's lock to settled> <slowest answer in ms>" (the slowest answer
# is the width of the hold it saw); on timeout, what it saw, and fails.
shell_settled() { # <seconds>
  local deadline=$((SECONDS + $1)) entrance="" streak=0 t0 ms slowest=0 answer acquired settled=""
  while ((SECONDS < deadline)); do
    if [[ -z $entrance ]]; then
      entrance=$(grep -m1 "grassfield-security: ready" "$lock_log" 2>/dev/null)
      [[ -n $entrance ]] || { sleep 0.25; continue; }
    fi
    t0=${EPOCHREALTIME/./}
    answer=$(ipc lock status)
    ms=$(((${EPOCHREALTIME/./} - t0) / 1000))
    ((ms > slowest)) && slowest=$ms
    if [[ -n $answer ]] && ((ms <= 500)); then streak=$((streak + 1)); else streak=0; fi
    ((streak >= 5)) && { settled=${EPOCHREALTIME/./}; break; }
    sleep 0.1
  done
  [[ -n $settled ]] || { echo "${entrance:+entrance logged, }slowest IPC answer $slowest ms"; return 1; }
  acquired=$(grep -m1 "grassfield-lock: locking -> locked (acquired)" "$lock_log" 2>/dev/null | cut -c1-23)
  if [[ -n $acquired ]]; then echo "$((settled / 1000 - $(date -d "$acquired" +%s%3N))) $slowest"; else echo "? $slowest"; fi
}

# Timing budget of the start-up hold: the slowest IPC answer shell_settled saw (the hold's width; 1.2-2.1 s in the
# integrator's run of 2026-11-04) at most <max> ms. Load-sensitive like the project's other timing budgets
# (scripts/dev/test.sh `load-sensitive`, tests/shell/stack_watch_cost.sh): with the 1-minute load above the core count it
# is reported as SKIP, never a pass and never enforced. Not acquired-to-settled: that adds the time to the entrance and
# the five-answer streak (about 4 s on the same run) and would hide the hold in noise.
load_above_cores() { awk -v n="$(nproc)" '{ exit !($1 > n) }' /proc/loadavg; }
hold_budget() { # <step> <slowest ms> <max ms>
  if [[ $2 =~ ^[0-9]+$ ]] && (($2 <= $3)); then
    pass "$1: the start-up held the shell's event loop at most $2 ms (<= $3)"
  elif load_above_cores; then
    echo "SKIP $1: start-up hold ${2:-?} ms (> $3) not judged at load $(cut -d' ' -f1 /proc/loadavg) (above $(nproc) cores)"
  else
    fail "$1: the start-up held the shell's event loop ${2:-?} ms (> $3 ms): the documented foreign-release gap widened (docs/specs/security.md, Known limitations)"
  fi
}

step_foreign_restart() {
  local s settled slowest
  foreign_start foreign-restart
  printf 'unlocked\n' >"$marker"
  echo "marker forged: $(cat "$marker")"
  restart_lock
  if s=$(restarted_status 15); then pass "foreign-restart: restarted security process status $s (took the foreign-held lock over)"; else fail "foreign-restart: restarted security process status $s"; fi
  grep "this shell did not take" "$lock_log" | tail -n 1
  # The release waits for the end of the restarted shell's start-up, so that the 150 ms bound below measures the ownership
  # check and not the start-up. A release inside the start-up is a residual risk (docs/specs/security.md, "Known
  # limitations"): its width is printed here, run after run.
  if settled=$(shell_settled 30); then
    read -r settled slowest <<<"$settled"
    echo "foreign-restart: the restarted shell's event loop settled $settled ms after its lock was acquired; slowest IPC answer meanwhile $slowest ms (a foreign release before then waits for that loop)"
    # The documented gap must not widen unnoticed (security review of 4e742050): the slowest answer is the hold's width.
    hold_budget foreign-restart "$slowest" "${HOLD_MAX_MS:-3000}"
  else
    fail "foreign-restart: the restarted security process's event loop did not settle within 30 s ($settled; .dev/security.log): the release below may measure its start-up"
  fi
  if s=$(wait_status locked 3); then pass "foreign-restart: status $s once the restarted shell settled"; else fail "foreign-restart: status $s once the restarted shell settled"; fi
  echo "foreign locker: $(foreign_ipc status)"
  no_leak restartforeign "foreign-restart (foreign locker present, shell restarted)"
  foreign_release_and_wait foreign-restart
  # The inherited lock keeps the 100 ms check even when a Grassfield surface holds the keyboard (R12 counter-review of
  # 620f08c: ending it on keyboard focus brought back the ~1 s window): the fresh lock must follow within 150 ms (the
  # same bound as before the settle wait above).
  assert_react foreign-restart "${FOREIGN_MAX_MS:-150}"
  echo "marker: $(cat "$marker" 2>/dev/null || echo '<missing>')"
  shot foreign-restart-relocked
  no_leak afterrestart "foreign-restart (after the foreign release)"
}

# Holds the pre-fix desync on purpose (positive control): the periodic ownership check is paused
# (dev hook, 10 s), the foreign locker takes the live lock over and releases it. Hyprland then
# reports the session unlocked while the shell still says "locked". Nothing is typed meanwhile.
desync_from=0
make_desync() { # <step>
  foreign_start "$1"
  echo "lock devPauseOwnershipCheck -> $(ipc lock devPauseOwnershipCheck)"
  desync_from=$(wc -l <"$lock_log")
  echo "foreign unlock -> $(foreign_ipc unlock)"
  foreign_wait_exit "$1"
  sleep 0.3
  local s
  s=$(ipc lock status)
  if ! compositor_locked && [[ $s == locked ]]; then
    pass "$1: desync held (control): Hyprland reports the session unlocked, shell status $s"
  else
    fail "$1: desync not reproduced (status $s, compositor $(compositor_lock))"
  fi
}

# The fresh lock must be triggered by <request> (logged before the re-lock), not by the paused check.
check_triggered_by() { # <step> <request log pattern>
  local order
  order=$(tail -n +"$((desync_from + 1))" "$lock_log" | grep -o -E "$2|taking a fresh lock" | head -n 2 | tr '\n' '|')
  if [[ $order == *"|taking a fresh lock|" && $order != "taking a fresh lock|"* ]]; then
    pass "$1: the fresh lock followed the request ($order)"
  else
    fail "$1: order '$order'"
  fi
}

# The time from "taking a fresh lock" to "locking -> locked (acquired)" (Hyprland's confirmation: every lock surface drew a
# frame) in the security log since line <from>: printed for the integrator's comparison (the nested run of 122f8d67 measured
# 5.05 s under load where the run of e1a3ff4c measured 0.43 s; since the surface draws its ground before LockView, the
# confirmation waits for that frame only).
confirm_time() { # <step> <log line count before>
  local ms
  ms=$(tail -n +"$(($2 + 1))" "$lock_log" | awk '
    function t(s,  a) { split(s, a, ":"); return ((a[1] * 60 + a[2]) * 60 + a[3]) * 1000 }
    /taking a fresh lock/ && from == "" { from = t($2) }
    /locking -> locked \(acquired\)/ && from != "" && to == "" { to = t($2) }
    END { if (from != "" && to != "") printf "%d", to - from }')
  if [[ -n $ms ]]; then echo "$1: fresh lock confirmed by Hyprland in $ms ms"; else echo "$1: no confirmation of the fresh lock in the log"; fi
}

step_lock_desync() {
  local s answer
  make_desync lock-desync
  answer=$(ipc lock lock)
  echo "lock lock during the desync -> $answer"
  for _ in $(seq 1 60); do compositor_locked && break; sleep 0.05; done
  if compositor_locked && s=$(wait_status locked 3); then pass "lock-desync: real lock after lock lock (status $s, compositor $(compositor_lock))"; else fail "lock-desync: status ${s:-?}, compositor $(compositor_lock)"; fi
  check_triggered_by lock-desync "lock requested \(ipc\) while locked"
  tail -n +"$((desync_from + 1))" "$lock_log" | grep -E "grassfield-lock"
  confirm_time lock-desync "$desync_from"
  shot lock-desync
  no_leak afterdesync "lock-desync"
}

# Before-sleep path (dev hook `idle devSleep`; no logind, no real inhibitor in nested): the sleep
# delay may only end on a confirmed lock. Control (really locked), then right after a desync, where
# "ready for sleep" must follow the fresh lock's "locking -> locked (acquired)".
sleep_new=""
sleep_wait() { # <name> <shell.log line count before>: sets sleep_new (log lines since), checks the ready line
  local ready=""
  for _ in $(seq 1 40); do
    sleep_new=$(tail -n +"$(($2 + 1))" "$lock_log")
    ready=$(grep -m1 "grassfield-idle: ready for sleep" <<<"$sleep_new")
    [[ -n $ready ]] && break
    sleep 0.1
  done
  grep -E "grassfield-lock|grassfield-idle" <<<"$sleep_new"
  echo "idle devSleep after -> $(ipc idle devSleep after)"
  if [[ $ready == *"(locked, lock confirmed)"* ]]; then pass "$1: the sleep delay ended on a confirmed lock"; else fail "$1: '${ready:-no ready line}'"; fi
}

step_sleep_desync() {
  local from order
  from=$(wc -l <"$lock_log")
  echo "idle devSleep before -> $(ipc idle devSleep before)"
  sleep_wait sleep-control "$from"
  make_desync sleep-desync
  echo "idle devSleep before -> $(ipc idle devSleep before)"
  sleep_wait sleep-desync "$desync_from"
  confirm_time sleep-desync "$desync_from"
  check_triggered_by sleep-desync "lock requested \(sleep\) while locked"
  order=$(grep -o -E "taking a fresh lock|locking -> locked \(acquired\)|ready for sleep" <<<"$sleep_new" | head -n 3 | tr '\n' '|')
  if [[ $order == "taking a fresh lock|locking -> locked (acquired)|ready for sleep|" ]]; then
    pass "sleep-desync: the sleep delay ended only after the fresh lock was acquired"
  else
    fail "sleep-desync: order '$order'"
  fi
  if compositor_locked; then pass "sleep-desync: Hyprland reports the session locked"; else fail "sleep-desync: compositor $(compositor_lock)"; fi
  no_leak aftersleep "sleep-desync"
}

# --- Forced races (R12 review #3) ---

typed_bytes() { stat -c %s "$typed" 2>/dev/null || echo 0; }

# "locked" (every monitor lists LOCK), "unlocked" (a valid answer where one does not) or "unknown: <answer>" (hyprctl
# failed or answered no monitor: proves nothing either way).
compositor_state() {
  local out
  out=$(nested hyprctl -j monitors 2>/dev/null)
  jq -er 'if type == "array" and length > 0 then (if all(.[]; (.solitaryBlockedBy // []) | index("LOCK") != null) then "locked" else "unlocked: " + tojson end) else "unknown" end' <<<"$out" 2>/dev/null \
    || echo "unknown: ${out:0:80}"
}

# Letters only (never Return), different for every run so that a leak can be attributed.
probe_word() { # <prefix> <n>
  local letters=abcdefghijklmnopqrstuvwxyz
  printf '%s%s%s' "$1" "${letters:$(($2 % 26)):1}" "${letters:$(($2 / 26 % 26)):1}"
}

# A stale "unlocked" answer (forged by the dev hook while the session is really locked) followed by `lock lock`
# must not relock: relock() releases the lock object first, and releasing the lock the compositor uses unlocks the
# session until the new lock arrives. Keys are typed across the request (every 4 ms, about 0.5 s).
step_relock_confirm() {
  local runs=${RELOCK_RUNS:-12} i from before after answer word typer unlocked unknown state s relocks=0 leaks=0 opened=0
  s=$(ipc lock status)
  [[ $s == locked ]] || { fail "relock-confirm: precondition: status $s (run the lock step first)"; return; }
  for i in $(seq 1 "$runs"); do
    wait_status locked 3 >/dev/null || { fail "relock-confirm run $i: status $(ipc lock status)"; continue; }
    sleep 0.6 # past the 500 ms grace of a lock just acquired
    from=$(wc -l <"$lock_log")
    before=$(typed_bytes)
    ipc lock devPauseOwnershipCheck >/dev/null
    answer=$(ipc lock devForgeUnlockedAnswer)
    [[ $answer == forged ]] || { fail "relock-confirm run $i: devForgeUnlockedAnswer -> '${answer:-no-answer}'"; continue; }
    word=$(probe_word relock "$i")
    bg_type "$word$word$word$word$word$word$word$word$word$word$word$word"
    sleep 0.05
    answer=$(ipc lock lock)
    unlocked=0 unknown=0
    for _ in $(seq 1 10); do
      state=$(compositor_state)
      case $state in
        locked) ;;
        unlocked*) unlocked=$((unlocked + 1)); echo "  $state" ;;
        *) unknown=$((unknown + 1)); echo "  $state" ;;
      esac
      sleep 0.03
    done
    wait "$typer"
    sleep 0.4
    after=$(typed_bytes)
    if tail -n +"$((from + 1))" "$lock_log" | grep -q "taking a fresh lock"; then relocks=$((relocks + 1)); fi
    ((after > before)) && leaks=$((leaks + 1))
    ((unlocked > 0)) && opened=$((opened + 1))
    echo "run $i: lock lock -> $answer; compositor answers without LOCK: $unlocked (no valid answer: $unknown); bytes that reached foot: $((after - before))"
  done
  press_key Escape # empty the lock field (Escape clears it; nothing is ever submitted)
  # The last dev pause (10 s) ends before the next step relies on the periodic check.
  for _ in $(seq 1 120); do
    tail -n +"$((from + 1))" "$lock_log" | grep -q "dev pause of the lock ownership check ended" && break
    sleep 0.1
  done
  echo "relock-confirm: $runs runs: relocks $relocks, runs with a key in foot $leaks, runs with an unlocked compositor answer $opened"
  if ((relocks == 0)); then pass "relock-confirm: no relock without a confirming answer ($runs runs)"; else fail "relock-confirm: relocked on an unconfirmed answer in $relocks of $runs runs"; fi
  if ((leaks == 0)); then pass "relock-confirm: nothing reached the foot window ($runs runs)"; else fail "relock-confirm: keys reached the foot window in $leaks of $runs runs"; fi
  if ((opened == 0)) && compositor_locked; then pass "relock-confirm: Hyprland reported LOCK throughout"; else fail "relock-confirm: Hyprland reported the session unlocked in $opened runs"; fi
}

# A foreign locker takes the live Grassfield lock over and releases it while keys are typed (every 4 ms): measures the
# unlocked window (foreign release -> Hyprland reports LOCK again) and the keys that reached foot during it.
step_foreign_gap() {
  local runs=${FOREIGN_RUNS:-5} max=${GAP_MAX_MS:-200} i s t0 t1 now lo hi before mid after word typer from released relocked react worst=0 polled=0 inGap=0 late=0
  for i in $(seq 1 "$runs"); do
    s=$(wait_status locked 3) || { fail "foreign-gap run $i: precondition: status $s"; return; }
    foreign_start "foreign-gap run $i"
    sleep 1 # the takeover settles; past the 500 ms grace of the last Grassfield lock
    before=$(typed_bytes)
    word=$(probe_word gap "$i")
    bg_type "$word$word$word$word$word$word$word$word$word$word$word$word$word$word$word$word"
    sleep 0.05
    from=$(wc -l <"$lock_log")
    t0=${EPOCHREALTIME/./}
    foreign_ipc unlock >/dev/null
    t1=${EPOCHREALTIME/./}
    lo="" hi=""
    for _ in $(seq 1 300); do
      if compositor_locked; then now=${EPOCHREALTIME/./}; lo=$(((now - t1) / 1000)); hi=$(((now - t0) / 1000)); break; fi
      sleep 0.005
    done
    mid=$(typed_bytes)
    wait "$typer"
    sleep 0.3
    after=$(typed_bytes)
    foreign_wait_exit "foreign-gap run $i"
    if [[ -z $hi ]]; then fail "foreign-gap run $i: Hyprland did not report LOCK again within 3 s"; continue; fi
    # Precise window: the fixture logs the epoch ms of its release, the shell log the time of its fresh lock request.
    react=""
    released=$(grep -o "unlocking on request at [0-9]*" "$dev/foreign-locker.log" | tail -n 1 | grep -o "[0-9]*$")
    relocked=$(tail -n +"$((from + 1))" "$lock_log" | grep -m1 "taking a fresh lock" | cut -c1-23)
    [[ -n $released && -n $relocked ]] && react=$(($(date -d "$relocked" +%s%3N) - released))
    if [[ -z $react ]]; then fail "foreign-gap run $i: no release time or no fresh lock in the logs"; continue; fi
    ((react > worst)) && worst=$react
    ((lo > polled)) && polled=$lo
    inGap=$((inGap + mid - before))
    late=$((late + after - mid))
    echo "run $i: foreign release -> fresh lock request ${react:-?} ms (shell log); -> LOCK seen by polling $lo ms after the release request returned ($hi ms before it was sent); bytes in foot: $((mid - before)) by then, $((after - mid)) after"
    no_leak "after$(probe_word gap "$i")" "foreign-gap run $i (typed after the fresh lock)"
  done
  echo "foreign-gap: $runs runs: worst release -> fresh lock request $worst ms (LOCK seen by polling within $polled ms, hyprctl and jq time included); bytes in foot during the windows $inGap, after them $late"
  if ((worst <= max)); then pass "foreign-gap: fresh lock requested <= $max ms after every foreign release (worst $worst ms)"; else fail "foreign-gap: fresh lock requested $worst ms after a foreign release (> $max ms)"; fi
  if ((polled <= 1500)); then pass "foreign-gap: Hyprland reported LOCK again within $polled ms of each release request"; else fail "foreign-gap: Hyprland reported LOCK again only after $polled ms"; fi
  # Bytes counted after the LOCK poll can still be keys typed inside the window (the poll costs tens of ms and foot ->
  # cat -> file adds lag): informational. The hard check is each run's probe typed after the fresh lock (no_leak above).
  echo "foreign-gap: bytes counted after the LOCK poll: $late (keys typed inside the window can land late; see the per-run probes)"
  # Leak control: Hyprland refocuses the window under the pointer when a foreign locker releases; foot only receives keys
  # in the window when it is that window (true right after `setup`; shell restarts in earlier steps can change it).
  ((inGap > 0)) || echo "foreign-gap: NOTE no key reached foot during any window: foot did not get the focus Hyprland restores, so the in-window count proves nothing in this run (run setup lock foreign-gap)"
  press_key Escape
}

# CPU time of a process in clock ticks (utime + stime: /proc/<pid>/stat fields 14 and 15; field 2 may hold spaces).
cpu_ticks() { # <pid>
  local stat rest
  stat=$(cat "/proc/$1/stat" 2>/dev/null) || { echo 0; return; }
  rest=${stat##*) }
  local -a f
  read -ra f <<<"$rest"
  echo $((f[11] + f[12]))
}

cpu_percent() { # <seconds> <pid>...: CPU % of each process over the interval, space separated
  local secs=$1 hz i out=""
  shift
  local -a a=() b=()
  hz=$(getconf CLK_TCK)
  for i in "$@"; do a+=("$(cpu_ticks "$i")"); done
  sleep "$secs"
  for i in "$@"; do b+=("$(cpu_ticks "$i")"); done
  for i in "${!a[@]}"; do out+=$(awk -v d=$((b[i] - a[i])) -v hz="$hz" -v s="$secs" 'BEGIN { printf " %.1f", 100 * d / hz / s }'); done
  echo "${out# }"
}

# Cost of the 100 ms ownership check while a takeover is suspected (a foreign locker holds the lock over Grassfield's),
# against the 1 s check of a plain lock: CPU of the shell and of the nested Hyprland over PROBE_COST_SECONDS (10).
step_probe_cost() {
  local secs=${PROBE_COST_SECONDS:-10} shellPid hyprPid plain held s from extra
  shellPid=$(lock_pid) && hyprPid=$(dev_live_pid "$dev/nested.pid") || { fail "probe-cost: no live security process or compositor record"; return; }
  s=$(wait_status locked 3) || { fail "probe-cost: precondition: status $s"; return; }
  sleep 1.5
  # A lock inherited at start (or one whose surface has no keyboard) already runs the 100 ms check: then there is no
  # 1 s baseline to compare with, and the comparison is informational (not a failure).
  local plainState="check every 1 s"
  suspected_now && plainState="already suspected: check every 100 ms (no 1 s baseline)"
  plain=$(cpu_percent "$secs" "$shellPid" "$hyprPid")
  foreign_start probe-cost
  sleep 1
  if suspected_now; then pass "probe-cost: takeover suspected while the foreign locker holds the lock"; else fail "probe-cost: no takeover suspected after the foreign takeover"; fi
  held=$(cpu_percent "$secs" "$shellPid" "$hyprPid")
  foreign_release_and_wait probe-cost
  echo "probe-cost: CPU % over $secs s (shell nested-Hyprland): plain lock ($plainState): $plain; foreign locker holding, check every 100 ms: $held"
  extra=$(awk -v a="$plain" -v b="$held" 'BEGIN { split(a, x, " "); split(b, y, " "); printf "%.1f", (y[1] + y[2]) - (x[1] + x[2]) }')
  if awk -v e="$extra" 'BEGIN { exit !(e < 5) }'; then pass "probe-cost: the suspected-takeover check adds $extra % CPU (< 5)"; else fail "probe-cost: the suspected-takeover check adds $extra % CPU"; fi
  # Absolute bound, whatever the baseline was: shell + nested Hyprland under 10 % CPU with the 100 ms check.
  if awk -v b="$held" 'BEGIN { split(b, y, " "); exit !(y[1] + y[2] < 10) }'; then pass "probe-cost: shell + Hyprland stay under 10 % CPU with the 100 ms check ($held)"; else fail "probe-cost: shell + Hyprland at $held % CPU with the 100 ms check"; fi
}

rss_mb() { awk '/^VmRSS:/ { printf "%.1f", $2 / 1024 }' "/proc/$1/status" 2>/dev/null; }

# Memory of the shell while the 100 ms ownership check runs (a foreign locker holds the lock over Grassfield's) for
# PROBE_MEMORY_SECONDS (default 600), RSS every 15 s. The JS heap makes a sawtooth (garbage builds up, a collection drops
# it), so two numbers: the garbage rate (sum of the rises, MB/min; what the per-probe allocation costs) and the retained
# growth (lowest RSS of the last third minus lowest of the middle third: a leak raises the post-collection floor).
# Fails when the retained growth reaches PROBE_MEMORY_MAX_RETAINED_MB (default 5). Not in the default sequence (10 min).
step_probe_memory() {
  local secs=${PROBE_MEMORY_SECONDS:-600} maxRetained=${PROBE_MEMORY_MAX_RETAINED_MB:-5} shellPid s from t0 now series="" stats rate retained
  shellPid=$(lock_pid) || { fail "probe-memory: no live security process record"; return; }
  s=$(wait_status locked 3) || { fail "probe-memory: precondition: status $s"; return; }
  from=$(wc -l <"$lock_log")
  foreign_start probe-memory
  sleep 1
  if ! tail -n +"$((from + 1))" "$lock_log" | grep -q "takeover suspected"; then
    [[ $(ipc lock status) == locked ]] && echo "probe-memory: (the shell was already in the suspected state)"
  fi
  t0=$SECONDS
  while ((SECONDS - t0 <= secs)); do
    now=$((SECONDS - t0))
    series+="$now $(rss_mb "$shellPid")"$'\n'
    sleep 15
  done
  foreign_release_and_wait probe-memory
  echo "probe-memory: shell RSS (s MB):"
  printf '%s' "$series" | awk '{ printf "  %4d s  %7.1f MB\n", $1, $2 }'
  stats=$(printf '%s' "$series" | awk -v secs="$secs" '
    { t[NR] = $1; m[NR] = $2 }
    END {
      up = 0; mid = 1e9; last = 1e9; lo = 1e9; hi = 0
      for (i = 1; i <= NR; i++) {
        if (i > 1 && m[i] > m[i - 1]) up += m[i] - m[i - 1]
        if (t[i] >= secs / 3 && t[i] < 2 * secs / 3 && m[i] < mid) mid = m[i]
        if (t[i] >= 2 * secs / 3 && m[i] < last) last = m[i]
        if (m[i] < lo) lo = m[i]; if (m[i] > hi) hi = m[i]
      }
      printf "%.1f %.1f %.1f %.1f", up / (t[NR] / 60), last - mid, lo, hi
    }')
  read -r rate retained lo hi <<<"$stats"
  echo "probe-memory: over $secs s: garbage rate $rate MB/min (sum of rises), retained growth $retained MB (floor of the last third minus floor of the middle third), RSS $lo-$hi MB"
  if awk -v r="$retained" -v m="$maxRetained" 'BEGIN { exit !(r < m) }'; then pass "probe-memory: no retained growth with the 100 ms check ($retained MB < $maxRetained)"; else fail "probe-memory: the post-collection floor grew $retained MB with the 100 ms check"; fi
}

# Leave nothing behind but the (locked) nested session.
step_cleanup() {
  echo "typed into foot: $(tr -c '[:alnum:]' ' ' <"$typed" 2>/dev/null)"
  dev_stop "$dev/reload-foot.pid" "probe foot" >/dev/null || true
  # A foreign locker still running (failed step): stop it; Hyprland keeps the session locked.
  dev_stop "$dev/foreign-locker.pid" "foreign locker" >/dev/null || true
}

# PAM attempt audit across EVERY shell instance this tree started (restarts overwrite $dev/shell.log, so read the
# Quickshell per-instance logs too). Must be 0: a real submit would count a faillock failure on the owner's account.
step_pam_audit() {
  local n s x new_s new_x
  read -r n s x < <(pam_counts)
  read -r new_s new_x < <(pam_new)
  echo "pam-audit: this run: $((n - pam_base_instances)) new shell instance(s); PAM submits $new_s; suppressed submits $new_x (all $n instance logs of this tree: submits $s, suppressed $x)"
  if ((new_s == 0)); then pass "pam-audit: no password was submitted to PAM during this run"; else fail "pam-audit: $new_s PAM submit(s) during this run: a faillock failure may have been counted on the real account"; fi
  ((new_x == 0)) || fail "pam-audit: $new_x key sequence(s) submitted the lock field (blocked by the dev PAM suppression, still a test defect)"
}

steps=("$@")
[[ ${#steps[@]} -gt 0 ]] || steps=(setup nowatch ui-down-sleep lock ui-crash relock-confirm foreign-gap probe-cost marker-missing marker-unlocked l1 forged-crash graceful-exit foreign-takeover foreign-restart lock-desync sleep-desync cleanup pam-audit)
assert_no_pam "before the run"
# Ready first (tests/security/nested_ready.sh): GF-REF listed (setup opens its window there) and a lock state from the
# shell. Right after nested-up the shell does not answer yet and GF-REF may not exist (the probe window once never
# appeared). A timeout FAILs: no step runs on an unknown state. Only cleanup and pam-audit need no shell.
needs_shell=0
for s in "${steps[@]}"; do [[ $s == cleanup || $s == pam-audit ]] || needs_shell=1; done
if ((needs_shell)); then
  ready_rc=0
  nested_ready "$sig" "$sock" "$lock_root" "$ready_secs" || ready_rc=$?
  case $ready_rc in
    0) echo "ready: GF-REF listed, lock status $nested_ready_state, after $nested_ready_ms ms" ;;
    2) echo "reload_locked: $nested_ready_why" >&2; exit 2 ;;
    *) echo "FAIL ready: $nested_ready_why (no step ran)"; exit 1 ;;
  esac
fi
for s in "${steps[@]}"; do
  echo "== $s"
  declare -F "step_${s//-/_}" >/dev/null || { echo "reload_locked: unknown step $s" >&2; exit 2; }
  "step_${s//-/_}"
  [[ $s == pam-audit ]] || assert_no_pam "after step $s"
done
exit $status
