#!/usr/bin/env bash
# GF-AUDIT-001 SEC-02 / GF-030 / D-12: lock coverage never disappears silently. Since ADR-0041 step 1, S2 the lock, idle and
# the sleep inhibitor run in the security process (grassfield-security.service), so every check below about "the process
# that locks" is about that unit, and the UI's unit (grassfield-shell.service) keeps only its restart and the failure counter.
#   gate     packaging/systemd/sleep-lock-gate (ExecCondition of Omarchy's omarchy-sleep-lock.service) skips Omarchy's
#            unit only in the Grassfield session while grassfield-security is up (active/running); it runs in the Omarchy
#            session and whenever grassfield-security is starting, waiting to restart after a crash (activating/auto-restart),
#            stopped, failed or unknown (a stub systemctl answers); the UI's state is never asked
#   drop-in  10-grassfield.conf uses the gate and no longer disables Omarchy's unit unconditionally
#   security grassfield-security.service restarts after ANY exit (Restart=always), has a start limit, starts Omarchy's unit
#            after every failure (OnFailure=, the fail-safe), never stops that unit (it may be delaying a sleep), and cannot
#            be restarted once the session target is gone
#   shell    grassfield-shell.service (the UI) restarts after any exit, keeps the failure counter as its only OnFailure=
#            (it holds no inhibitor and no lock since S2)
#   stand-in packaging/shims/omarchy-shell (what Omarchy's sleep-lock calls in this session): `lock lock` starts a
#            stopped or failed grassfield-security again and asks it to lock (the security instance's path); `lock status`
#            reports secure only when Hyprland lists LOCK on every monitor; every other call fails; nothing unlocks (stub
#            systemctl, qs, hyprctl)
#   package  the PKGBUILD installs the gate where the drop-in looks for it, executable
# The runtime proof (SIGTERM / qs kill -> restarted within 3 s) is owner step L2-12 and tests/security/reload_locked.sh
# `graceful-exit` (nested). Plain shell test: prints PASS/FAIL, exits non-zero on failure.
set -euo pipefail
root=$(git -C "$(dirname "$0")" rev-parse --show-toplevel)
cd "$root"
fail=0
pass() { echo "PASS: sleep-lock units $*"; }
bad() { echo "FAIL: sleep-lock units $*"; fail=1; }
tmp=$(mktemp -d "${GRASSFIELD_TEST_TMP:-${TMPDIR:-/tmp}}/sleep-lock-units.XXXXXX")
trap 'rm -rf "$tmp"' EXIT

# --- gate: a stub systemctl prints the ActiveState and SubState the case wants (or fails) ---
mkdir -p "$tmp/bin"
cat >"$tmp/bin/systemctl" <<'SH'
#!/bin/sh
[ "$STUB_STATE" = "<fail>" ] && exit 1
case "$*" in
  "--user show --property=ActiveState --value grassfield-security.service") printf '%s\n' "$STUB_STATE" ;;
  "--user show --property=SubState --value grassfield-security.service") printf '%s\n' "$STUB_SUBSTATE" ;;
  *) echo "unexpected: $*" >&2; exit 9 ;;
esac
SH
chmod +x "$tmp/bin/systemctl"
gate() { # <GRASSFIELD_SESSION or -> <ActiveState> <SubState> -> prints the gate's exit code
  local session=$1 rc=0
  if [[ $session == - ]]; then
    env -i PATH="$tmp/bin:/usr/bin:/bin" STUB_STATE="$2" STUB_SUBSTATE="$3" sh packaging/systemd/sleep-lock-gate || rc=$?
  else
    env -i PATH="$tmp/bin:/usr/bin:/bin" STUB_STATE="$2" STUB_SUBSTATE="$3" GRASSFIELD_SESSION="$session" sh packaging/systemd/sleep-lock-gate || rc=$?
  fi
  echo "$rc"
}
# GF-081 / D-12: the only "session ending" signal is "the compositor is gone" (its Wayland socket or its Hyprland instance
# directory no longer exists). The session target is never read: at login it still reads inactive. A regular file stands in for
# the socket (the gate only tests that the path exists). Undecidable input arms the lock.
cgate() { # <shell ActiveState> <WAYLAND_DISPLAY or -> <HYPRLAND_INSTANCE_SIGNATURE or -> [unset-runtime] -> the gate's exit code
  local rc=0 e=(PATH="$tmp/bin:/usr/bin:/bin" STUB_STATE="$1" STUB_SUBSTATE="${1/active/running}" GRASSFIELD_SESSION=1)
  [[ ${4:-} == unset-runtime ]] || e+=(XDG_RUNTIME_DIR="$tmp/run")
  [[ $2 == - ]] || e+=(WAYLAND_DISPLAY="$2")
  [[ $3 == - ]] || e+=(HYPRLAND_INSTANCE_SIGNATURE="$3")
  env -i "${e[@]}" sh packaging/systemd/sleep-lock-gate || rc=$?
  echo "$rc"
}
mkdir -p "$tmp/run/hypr/sig-live"
: >"$tmp/run/wayland-live"
rm -rf "$tmp/run/wayland-gone" "$tmp/run/hypr/sig-gone"
[[ $(cgate inactive wayland-live sig-live) == 0 ]] && pass "gate: LOGIN (shell not up yet, compositor live) -> Omarchy's unit runs: D-12 holds from login" || bad "gate: login did not run"
[[ $(cgate failed wayland-live sig-live) == 0 ]] && pass "gate: CRASH mid-session (shell failed, compositor live) -> Omarchy's unit runs" || bad "gate: crash did not run"
[[ $(cgate failed wayland-gone sig-live) == 1 ]] && pass "gate: LOGOUT (the Wayland socket is gone, shell failed 255) -> skipped" || bad "gate: logout (socket gone) not skipped"
[[ $(cgate failed wayland-live sig-gone) == 1 ]] && pass "gate: LOGOUT (the Hyprland instance directory is gone) -> skipped" || bad "gate: logout (instance gone) not skipped"
[[ $(cgate failed - -) == 0 ]] && pass "gate: undecidable (no WAYLAND_DISPLAY, no signature) -> runs (fail closed)" || bad "gate: undecidable did not run"
[[ $(cgate failed wayland-gone - unset-runtime) == 0 ]] && pass "gate: undecidable (relative display, no XDG_RUNTIME_DIR) -> runs" || bad "gate: undecidable (no runtime dir) did not run"
[[ $(cgate failed "$tmp/run/wayland-live" -) == 0 ]] && pass "gate: absolute WAYLAND_DISPLAY that exists -> runs" || bad "gate: absolute live path did not run"
[[ $(cgate failed "$tmp/run/wayland-gone" -) == 1 ]] && pass "gate: absolute WAYLAND_DISPLAY that is gone -> skipped" || bad "gate: absolute gone path not skipped"
[[ $(cgate active wayland-live sig-live) == 1 ]] && pass "gate: security process active/running with the compositor live -> skipped (it holds its own inhibitor)" || bad "gate: running security process not skipped"
grep -v '^[[:space:]]*#' packaging/systemd/sleep-lock-gate | grep -q "grassfield-shell" && bad "gate: asks the UI's unit (the sleep question is the security process's alone since S2)" \
  || pass "gate: keyed on grassfield-security alone, never on the UI's grassfield-shell (S2)"
# "Compositor gone" is decided only when ENOENT is certain (parent searchable, well-formed path of sane length, nothing there, not
# even a dangling link); every other error is undecidable and arms the lock (review: EACCES must not read as "absent").
rawgate() { local rc=0; env -i PATH="$tmp/bin:/usr/bin:/bin" STUB_STATE=failed STUB_SUBSTATE=failed GRASSFIELD_SESSION=1 "$@" sh packaging/systemd/sleep-lock-gate || rc=$?; echo "$rc"; }
long300=$(printf 'w%.0s' $(seq 1 300))
long5000=/$(printf 'a%.0s' $(seq 1 5000))
if [[ $(id -u) == 0 ]]; then
  echo "SKIP: gate with an unreadable runtime directory (root reads everything)"
else
  mkdir -p "$tmp/rd000" "$tmp/rdsub/inner"
  : >"$tmp/rd000/wl"; : >"$tmp/rdsub/inner/wl"
  chmod 000 "$tmp/rd000"; chmod 000 "$tmp/rdsub/inner"
  [[ $(rawgate XDG_RUNTIME_DIR="$tmp/rd000" WAYLAND_DISPLAY=wl) == 0 ]] && pass "gate: runtime directory mode 000 (socket unreadable, EACCES) -> runs, not 'gone'" || bad "gate: unreadable runtime dir skipped"
  [[ $(rawgate WAYLAND_DISPLAY="$tmp/rdsub/inner/wl") == 0 ]] && pass "gate: absolute socket path under an unsearchable directory -> runs" || bad "gate: unsearchable parent skipped"
  [[ $(rawgate XDG_RUNTIME_DIR="$tmp/rd000" HYPRLAND_INSTANCE_SIGNATURE=sig) == 0 ]] && pass "gate: instance directory under an unreadable runtime directory -> runs" || bad "gate: unreadable hypr dir skipped"
  chmod 700 "$tmp/rd000" "$tmp/rdsub/inner"
fi
[[ $(rawgate XDG_RUNTIME_DIR="$tmp/run" WAYLAND_DISPLAY="$long300") == 0 ]] && pass "gate: a 300-character WAYLAND_DISPLAY (ENAMETOOLONG) -> runs" || bad "gate: over-long display skipped"
[[ $(rawgate WAYLAND_DISPLAY="$long5000") == 0 ]] && pass "gate: an absolute path over 4096 characters -> runs" || bad "gate: over-long absolute path skipped"
[[ $(rawgate XDG_RUNTIME_DIR="$tmp/run" WAYLAND_DISPLAY=../escape) == 0 ]] && pass "gate: a display with .. or a slash is not a socket name -> runs" || bad "gate: odd display skipped"
[[ $(rawgate XDG_RUNTIME_DIR="$tmp/run" HYPRLAND_INSTANCE_SIGNATURE=../x) == 0 ]] && pass "gate: an instance signature that is not a plain name -> runs" || bad "gate: odd signature skipped"
ln -sf "$tmp/run/nowhere" "$tmp/run/dangling"
[[ $(rawgate XDG_RUNTIME_DIR="$tmp/run" WAYLAND_DISPLAY=dangling) == 0 ]] && pass "gate: a dangling link at the socket path is not 'definitely absent' -> runs" || bad "gate: dangling link skipped"
[[ $(rawgate XDG_RUNTIME_DIR="$tmp/run" WAYLAND_DISPLAY=wayland-certainly-gone) == 1 ]] && pass "gate: a plain missing socket in a searchable runtime directory -> skipped (ENOENT certain)" || bad "gate: missing socket not skipped"
mkdir -p "$tmp/run/hypr/stale-1" "$tmp/run/hypr/stale-2"
[[ $(cgate failed wayland-live sig-gone) == 1 ]] && pass "gate: stale instance directories of other sessions do not count: the session's own instance is absent -> skipped" || bad "gate: stale directories counted as this session"
[[ $(cgate failed wayland-live stale-1) == 0 ]] && pass "gate: the session's own instance directory is the one checked (present -> runs)" || bad "gate: own instance directory ignored"
if grep -v '^[[:space:]]*#' packaging/systemd/sleep-lock-gate | grep -q "graphical-session.target"; then bad "gate: reads the session target (it reads inactive at login)"; else pass "gate: never reads graphical-session.target"; fi
[[ $(gate 1 active running) == 1 ]] && pass "gate: Grassfield session, grassfield-security active/running -> Omarchy's unit skipped" \
  || bad "gate: Grassfield session, grassfield-security active/running -> not skipped"
# N1: after a crash the shell is activating/auto-restart, then activating/start: no Grassfield inhibitor exists then.
for pair in "activating auto-restart" "activating start" "active exited" "reloading running" "inactive dead" "failed failed" \
  "deactivating stop-sigterm" "maintenance dead" "<fail> x"; do
  read -r unit_state unit_sub <<<"$pair"
  [[ $(gate 1 "$unit_state" "$unit_sub") == 0 ]] && pass "gate: Grassfield session, grassfield-security '$pair' -> Omarchy's unit runs" \
    || bad "gate: Grassfield session, grassfield-security '$pair' -> skipped"
done
[[ $(gate 1 "" "") == 0 ]] && pass "gate: Grassfield session, no answer -> Omarchy's unit runs" || bad "gate: no answer -> skipped"
for session in - 0 ""; do
  [[ $(gate "$session" active running) == 0 ]] && pass "gate: not the Grassfield session (GRASSFIELD_SESSION '$session') -> Omarchy's unit runs" \
    || bad "gate: GRASSFIELD_SESSION '$session' -> skipped"
done
[[ -x packaging/systemd/sleep-lock-gate ]] && pass "gate: executable in the tree" || bad "gate: not executable"

# --- drop-in ---
dropin=packaging/systemd/omarchy-sleep-lock.service.d/10-grassfield.conf
grep -qx 'ExecCondition=/usr/lib/grassfield/sleep-lock-gate' "$dropin" && pass "drop-in: ExecCondition is the gate" || bad "drop-in: no gate"
if grep -v '^#' "$dropin" | grep -q 'ConditionEnvironment'; then bad "drop-in: still disables Omarchy's unit by environment"; else pass "drop-in: no unconditional ConditionEnvironment"; fi
grep -q '^\[Service\]' "$dropin" && pass "drop-in: [Service] section" || bad "drop-in: ExecCondition outside [Service]"

# --- grassfield-security.service: the process that locks (S2) ---
sec=packaging/systemd/grassfield-security.service
secactive=$(grep -v '^#' "$sec")
grep -qx 'Restart=always' <<<"$secactive" && grep -qx 'RestartSec=1' <<<"$secactive" && pass "security: Restart=always, RestartSec=1" || bad "security: restart"
grep -qx 'Requisite=graphical-session.target' <<<"$secactive" && grep -qx 'PartOf=graphical-session.target' <<<"$secactive" \
  && pass "security: tied to the session target (logout is not fought)" || bad "security: Requisite/PartOf missing"
awk '/^\[Unit\]/{u=1;next} /^\[/{u=0} u && /^OnFailure=omarchy-sleep-lock\.service$/{found=1} END{exit !found}' "$sec" \
  && pass "security: every failure of the process that holds the inhibitor starts Omarchy's sleep-lock ([Unit] OnFailure=, S2)" || bad "security: no OnFailure=omarchy-sleep-lock.service in [Unit]"
grep -q 'stop omarchy-sleep-lock' <<<"$secactive" && bad "security: stops Omarchy's sleep-lock (could cut a sleep it is delaying)" \
  || pass "security: never stops Omarchy's sleep-lock"

# --- grassfield-shell.service: the UI (holds no lock and no inhibitor since S2) ---
unit=packaging/systemd/grassfield-shell.service
active=$(grep -v '^#' "$unit")
grep -qx 'Restart=always' <<<"$active" && pass "shell: Restart=always (clean exits, SIGTERM and qs kill restart too)" || bad "shell: not Restart=always"
grep -q '^Restart=on-failure' <<<"$active" && bad "shell: Restart=on-failure left" || pass "shell: no Restart=on-failure"
grep -qx 'RestartSec=1' <<<"$active" && pass "shell: RestartSec=1 (gate R1: back within 3 s)" || bad "shell: RestartSec"
grep -qE '^StartLimitIntervalSec=[0-9]+$' <<<"$active" && grep -qE '^StartLimitBurst=[0-9]+$' <<<"$active" \
  && pass "shell: start limit set (a crash loop ends)" || bad "shell: no start limit"
grep -qx 'Requisite=graphical-session.target' <<<"$active" && grep -qx 'PartOf=graphical-session.target' <<<"$active" \
  && pass "shell: tied to the session target (logout is not fought)" || bad "shell: Requisite/PartOf missing"
grep -q '^OnFailure=.*omarchy-sleep-lock' <<<"$active" && bad "shell: the UI still arms Omarchy's sleep-lock (S2 moved it to grassfield-security.service)" \
  || pass "shell: the UI no longer arms Omarchy's sleep-lock (S2: the security process holds the inhibitor and arms it)"
# ADR-0041 step 1a (owner decision SQ-2 A): the failure counter is the second OnFailure= unit; it stops a crash loop of any pace
# at the third failure within 10 minutes and never unlocks (tests/shell/shell_failures.sh has its decisions); the start limit
# is the backstop (10 starts in 5 minutes). The counter, like the gate, asks session-gone whether the compositor is certainly
# gone, so a logout's exit 255 counts nothing.
grep -qx 'OnFailure=grassfield-shell-failed.service' "$unit" \
  && pass "shell: the failure counter (grassfield-shell-failed.service) is started after every failure" || bad "shell: OnFailure= does not name grassfield-shell-failed.service alone"
grep -qx 'StartLimitIntervalSec=300' "$unit" && grep -qx 'StartLimitBurst=10' "$unit" \
  && pass "shell: the start limit is the backstop, 10 starts in 5 minutes (SQ-2 A)" || bad "shell: the start limit is not 10 in 300 s"
[[ -x packaging/systemd/session-gone ]] && grep -q 'dirname "\$0")/session-gone' packaging/systemd/sleep-lock-gate && grep -q 'dirname "\$0")/session-gone' packaging/bin/grassfield-shell-failed \
  && pass "session-gone: one shared test of 'the compositor is certainly gone', used by the gate and by the counter" || bad "session-gone: not shared by the gate and the counter"
if grep -v '^[[:space:]]*#' packaging/systemd/session-gone | grep -q "graphical-session.target\|systemctl"; then bad "session-gone: reads the session target or systemd (it must decide from files only)"; else pass "session-gone: decides from the socket and the instance directory only"; fi
grep -q 'install -Dm755 "$root/packaging/systemd/session-gone" "$pkgdir/usr/lib/grassfield/session-gone"' packaging/arch/PKGBUILD && grep -q 'for unit in .*shell-failed' packaging/arch/PKGBUILD \
  && pass "package: session-gone is installed next to the gate and the counter's unit is installed" || bad "package: session-gone or grassfield-shell-failed.service not installed"
grep -q 'stop omarchy-sleep-lock' <<<"$active" && bad "shell: stops Omarchy's sleep-lock (could cut a sleep it is delaying)" \
  || pass "shell: never stops Omarchy's sleep-lock"
awk '/^\[Unit\]/{u=1;next} /^\[/{u=0} u && /^StartLimit/{found=1} END{exit !found}' "$unit" \
  && pass "shell: start limit in [Unit]" || bad "shell: start limit not in [Unit]"

# --- the omarchy-shell stand-in (stub systemctl, qs and hyprctl record their calls) ---
shim=packaging/shims/omarchy-shell
mkdir -p "$tmp/sbin" "$tmp/run"
cat >"$tmp/sbin/systemctl" <<'SH'
#!/bin/sh
echo "systemctl $*" >>"$STUB_LOG"
case "$*" in
  "--user show --property=ActiveState --value grassfield-security.service") printf '%s\n' "$STUB_STATE" ;;
esac
exit 0
SH
cat >"$tmp/sbin/qs" <<'SH'
#!/bin/sh
echo "qs $*" >>"$STUB_LOG"
case "$*" in
  "ipc -p /usr/share/grassfield/shell/security.qml call lock lock") ;;
  "ipc -p /usr/share/grassfield/shell call update check omarchy") [ -n "$STUB_QS" ] || exit 1; echo ok; exit 0 ;;
  "ipc -p /usr/share/grassfield/shell/security.qml call security state") [ -n "$STUB_SECSTATE" ] || exit 1; printf '%s\n' "$STUB_SECSTATE"; exit 0 ;;
  *) exit 9 ;;
esac
[ -n "$STUB_QS" ] || exit 1
printf '%s\n' "$STUB_QS"
SH
cat >"$tmp/sbin/hyprctl" <<'SH'
#!/bin/sh
echo "hyprctl $*" >>"$STUB_LOG"
[ "$*" = "-j monitors" ] || exit 9
printf '%s\n' "$STUB_MONITORS"
SH
# The stand-in's retry loop (lock lock: up to 100 tries of qs, `sleep 0.1` between them, a 10 s budget) is counted, not
# waited out: a stub sleep records each pause. With real pauses the "never answers" case needed 10 s of sleep plus 100
# rounds of forks inside the hang guard, and timed out (rc 124) on a loaded machine (12.0 s at load 14 on 8 cores).
cat >"$tmp/sbin/sleep" <<'SH'
#!/bin/sh
echo "sleep $*" >>"$STUB_LOG"
SH
chmod +x "$tmp/sbin/systemctl" "$tmp/sbin/qs" "$tmp/sbin/hyprctl" "$tmp/sbin/sleep"
# Hang guard only (no case measures time): generous, so that a slow fork on a loaded machine never reads as a failure.
shim_guard=120
shimrun() { # <state> <qs answer> <monitors json> args... -> stdout; exit status in $shim_rc
  local state=$1 answer=$2 monitors=$3
  shift 3
  : >"$tmp/log"
  shim_rc=0
  env -i PATH="$tmp/sbin:/usr/bin:/bin" STUB_LOG="$tmp/log" STUB_STATE="$state" STUB_QS="$answer" STUB_MONITORS="$monitors" \
    STUB_SECSTATE="${secstate:-}" XDG_RUNTIME_DIR="$tmp/run" HYPRLAND_INSTANCE_SIGNATURE="sig/1 x" timeout "$shim_guard" sh "$shim" "$@" 2>/dev/null || shim_rc=$?
}
locked='[{"name":"eDP-1","solitaryBlockedBy":["LOCK"]},{"name":"DP-1","solitaryBlockedBy":["LOCK","WINDOWED"]}]'
half='[{"name":"eDP-1","solitaryBlockedBy":["LOCK"]},{"name":"DP-1","solitaryBlockedBy":["WINDOWED"]}]'

out=$(shimrun active ok "$locked" lock lock; echo "rc=$shim_rc")
[[ $out == $'ok\nrc=0' ]] && ! grep -q "start\|reset-failed" "$tmp/log" && grep -qx "qs ipc -p /usr/share/grassfield/shell/security.qml call lock lock" "$tmp/log" \
  && pass "stand-in: lock lock with grassfield-security running asks it to lock (the security instance), starts nothing" || bad "stand-in: running security process: $out / $(tr '\n' ';' <"$tmp/log")"
# An upgrade from a build before ADR-0041 S2 leaves the earlier security process running: it hosts no lock and its
# `security state` answers "starting" (the opus review of 77a0ceb3, MINOR-1). The stand-in restarts it (no-block) so the
# new one hosts the lock; a process of S2 (any other answer, or none) is left alone.
secstate=starting
out=$(shimrun active ok "$locked" lock lock; echo "rc=$shim_rc")
grep -qx "systemctl --user restart --no-block grassfield-security.service" "$tmp/log" && ! grep -q "reset-failed\|grassfield-shell.service" "$tmp/log" \
  && grep -qx "qs ipc -p /usr/share/grassfield/shell/security.qml call lock lock" "$tmp/log" && [[ $out == $'ok\nrc=0' ]] \
  && pass "stand-in: lock lock next to a security process from before S2 (security state: starting) restarts it (no-block), then asks it to lock" \
  || bad "stand-in: pre-S2 security process: $out / $(tr '\n' ';' <"$tmp/log")"
for secstate in "lock idle" "lock idle polkit secrets" "lock sleep" ""; do
  out=$(shimrun active ok "$locked" lock lock; echo "rc=$shim_rc")
  ! grep -q "restart\|reset-failed" "$tmp/log" && [[ $out == $'ok\nrc=0' ]] \
    && pass "stand-in: lock lock next to a security process of S2 or S3 (security state: '${secstate:-no answer}') restarts nothing" \
    || bad "stand-in: S2 security process '${secstate}': $out / $(tr '\n' ';' <"$tmp/log")"
done
secstate=
for state in failed inactive; do
  out=$(shimrun "$state" ok "$locked" lock lock; echo "rc=$shim_rc")
  grep -qx "systemctl --user reset-failed grassfield-security.service" "$tmp/log" && grep -qx "systemctl --user start --no-block grassfield-security.service" "$tmp/log" \
    && grep -qx "qs ipc -p /usr/share/grassfield/shell/security.qml call lock lock" "$tmp/log" && [[ $out == $'ok\nrc=0' ]] \
    && ! grep -q "grassfield-shell.service" "$tmp/log" \
    && pass "stand-in: lock lock with grassfield-security $state starts it again (reset-failed, no-block) and asks it to lock; the UI's unit is never touched" \
    || bad "stand-in: security process $state: $out / $(tr '\n' ';' <"$tmp/log")"
done
out=$(shimrun failed "" "$locked" lock lock; echo "rc=$shim_rc")
tries=$(grep -cx "qs ipc -p /usr/share/grassfield/shell/security.qml call lock lock" "$tmp/log" || true)
naps=$(grep -cx "sleep 0.1" "$tmp/log" || true)
others=$(grep -vc "^qs ipc -p /usr/share/grassfield/shell/security.qml call lock lock$\|^sleep 0.1$\|^systemctl --user " "$tmp/log" || true)
[[ $out == "rc=1" && $tries == 100 && $naps == 100 && $others == 0 ]] \
  && pass "stand-in: a security process that never answers -> failure after exactly 100 tries 0.1 s apart (a bounded 10 s; Omarchy keeps asking, then reports it)" \
  || bad "stand-in: no answer gave '$out' after $tries tries and $naps pauses ($others other calls)"
out=$(shimrun active ok "$locked" lock status)
[[ $(jq -r '.secure' <<<"$out") == true ]] && pass "stand-in: status secure when Hyprland lists LOCK on every monitor" || bad "stand-in: status '$out' with LOCK everywhere"
out=$(shimrun active ok "$half" lock status)
[[ $(jq -r '.secure' <<<"$out") == false ]] && pass "stand-in: status not secure when one monitor lacks LOCK" || bad "stand-in: status '$out' with a monitor unlocked"
out=$(shimrun active ok "[]" lock status)
[[ $(jq -r '.secure' <<<"$out") == false ]] && pass "stand-in: status not secure without a monitor answer" || bad "stand-in: status '$out' without monitors"
# Fail closed on another shape of the answer (tests/fuzz/fuzz_helpers.py lock-status): a string holding "LOCK" as a substring,
# an object instead of an array, a non-JSON answer are never secure.
# ... and several JSON values (`jq -e` without -s decides on the last one; the integrator's review of 265e6c7, major 1).
for odd in '[{"name":"eDP-1","solitaryBlockedBy":"UNLOCKED"}]' '[{"name":"eDP-1","solitaryBlockedBy":"LOCK"}]' '[{"name":"eDP-1","solitaryBlockedBy":{"LOCK":1}}]' 'not json' '[{"name":"eDP-1"}]' '{"a":{"name":"eDP-1","solitaryBlockedBy":["LOCK"]}}' '"LOCK"' \
  '[{"name":"eDP-1","solitaryBlockedBy":["WINDOWED"]}] [{"name":"eDP-1","solitaryBlockedBy":["LOCK"]}]' '4294967296[{"name":"eDP-1","solitaryBlockedBy":["LOCK"]}]' \
  '[{"name":"eDP-1","solitaryBlockedBy":["LOCK"]}] 1' ''; do
  out=$(shimrun active ok "$odd" lock status)
  [[ $(jq -r '.secure' <<<"$out") == false ]] && pass "stand-in: status not secure for the answer $odd" || bad "stand-in: status '$out' for the answer $odd"
done
[[ $(jq -r '.requested' <<<"$out") == false ]] && pass "stand-in: not requested without the crash-recovery marker" || bad "stand-in: requested '$out'"
for line in "locked" "locked sleeps=12"; do
  printf '%s\n' "$line" >"$tmp/run/grassfield-lock-sig_1_x"
  out=$(shimrun active ok "$half" lock status)
  [[ $(jq -r '.requested' <<<"$out") == true ]] && pass "stand-in: requested once the marker (LockMachine.markerName) says '$line'" || bad "stand-in: marker '$line' ignored: '$out'"
done
for line in "unlocked sleeps=12" "unlocked" "lockedx"; do
  printf '%s\n' "$line" >"$tmp/run/grassfield-lock-sig_1_x"
  out=$(shimrun active ok "$half" lock status)
  [[ $(jq -r '.requested' <<<"$out") == false ]] && pass "stand-in: not requested with the marker '$line'" || bad "stand-in: marker '$line' read as requested: '$out'"
done
for args in "lock unlock" "notifications dismissAll" "shell toggle omarchy.menu"; do
  out=$(shimrun active ok "$locked" $args; echo "rc=$shim_rc")
  [[ $out == "rc=1" ]] && ! grep -q "^qs \|systemctl --user start" "$tmp/log" && pass "stand-in: '$args' fails and does nothing" || bad "stand-in: '$args' -> $out / $(tr '\n' ';' <"$tmp/log")"
done
# Omarchy's update status (ADR-0033 U9): forwarded as one check request, nothing else started.
for verb in refresh clear; do
  out=$(shimrun active ok "$locked" -q omarchy.system-update "$verb"; echo "rc=$shim_rc")
  [[ $out == "rc=0" && $(cat "$tmp/log") == "qs ipc -p /usr/share/grassfield/shell call update check omarchy" ]] \
    && pass "stand-in: -q omarchy.system-update $verb sends one 'update check omarchy' to the shell, starts nothing" \
    || bad "stand-in: omarchy.system-update $verb -> $out / $(tr '\n' ';' <"$tmp/log")"
done
out=$(shimrun failed "" "$locked" -q omarchy.system-update refresh; echo "rc=$shim_rc")
[[ $out == "rc=0" ]] && ! grep -q "systemctl --user start" "$tmp/log" \
  && pass "stand-in: no shell to ask: -q omarchy.system-update refresh is a silent success that starts nothing (omarchy update goes on)" \
  || bad "stand-in: no shell: $out / $(tr '\n' ';' <"$tmp/log")"
out=$(shimrun failed "" "$locked" omarchy.system-update refresh; echo "rc=$shim_rc")
[[ $out == "rc=1" ]] && pass "stand-in: without -q, no shell to ask is a failure" || bad "stand-in: no shell without -q gave $out"
out=$(shimrun active ok "$locked" omarchy.system-update install; echo "rc=$shim_rc")
[[ $out == "rc=1" ]] && ! grep -q "^qs " "$tmp/log" && pass "stand-in: another omarchy.system-update verb fails and does nothing" || bad "stand-in: omarchy.system-update install -> $out"
out=$(shimrun active ok "$locked" -q lock unlock; echo "rc=$shim_rc")
[[ $out == "rc=0" ]] && ! grep -q "^qs " "$tmp/log" && pass "stand-in: -q makes an unknown call a silent success, still doing nothing" || bad "stand-in: -q gave $out"
grep -q "unlock_and_destroy\|lock unlock\|call lock release" "$shim" && bad "stand-in: mentions an unlock call" || pass "stand-in: has no unlock path"

# --- the clamshell stand-in (N4): Omarchy's sleep-lock and wake scripts call omarchy-hyprland-monitor-clamshell; in this
# session it must hand over to grassfield-lid's own reconcile instead of Omarchy's panel switching ---
clam=packaging/shims/omarchy-hyprland-monitor-clamshell
printf '#!/bin/sh\necho "lid $*" >>"$STUB_LOG"\n' >"$tmp/sbin/grassfield-lid"
chmod +x "$tmp/sbin/grassfield-lid"
: >"$tmp/log"
# A dev session: the stand-in honours GRASSFIELD_LID_TOOL only there (the real-session case: lock_request_env.sh).
env -i PATH="$tmp/sbin:/usr/bin:/bin" STUB_LOG="$tmp/log" GRASSFIELD_DEV=1 GRASSFIELD_LID_TOOL="$tmp/sbin/grassfield-lid" sh "$clam" && rc=0 || rc=$?
[[ $rc == 0 && $(cat "$tmp/log") == "lid reconcile" ]] && pass "clamshell stand-in: runs grassfield-lid reconcile, nothing else" || bad "clamshell stand-in: rc $rc, calls '$(cat "$tmp/log")'"
env -i PATH="/usr/bin:/bin" GRASSFIELD_DEV=1 GRASSFIELD_LID_TOOL="$tmp/none" sh "$clam" && pass "clamshell stand-in: without grassfield-lid it does nothing and succeeds" || bad "clamshell stand-in: fails without grassfield-lid"
grep -v '^#' "$clam" | grep -q "hyprctl\|monitors.lua\|toggles" && bad "clamshell stand-in: touches monitors itself" || pass "clamshell stand-in: never touches monitors itself"

# --- package ---
grep -q 'install -Dm755 "$root/packaging/systemd/sleep-lock-gate" "$pkgdir/usr/lib/grassfield/sleep-lock-gate"' packaging/arch/PKGBUILD \
  && pass "package: the gate is installed where the drop-in looks for it" || bad "package: gate not installed at /usr/lib/grassfield/sleep-lock-gate"
exit $fail
