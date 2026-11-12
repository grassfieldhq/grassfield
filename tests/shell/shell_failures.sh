#!/usr/bin/env bash
# ADR-0041 step 1a (owner decision SQ-2 A): packaging/bin/grassfield-shell-failed, the shell's failure counter that
# grassfield-shell.service starts through OnFailure= after every failure. Against stubs (systemctl logs its calls, a
# session-gone stand-in answers what the case wants, the clock is given): no session, no systemd, nothing real is touched.
#   - the first and second failure within 10 minutes count and stop nothing; the third stops the shell unit once and writes
#     the safe-mode state; failures older than the window are forgotten; a logout (the compositor gone) counts nothing;
#   - a ledger that is garbage, a symlink, from the future, a missing runtime directory or an unreadable clock never stop
#     the shell: a counter that cannot count counts nothing (the restarts go on);
#   - the only command it runs is `systemctl --user stop grassfield-shell.service`; nothing unlocks;
#   - mutants: without the session-gone check a logout counts; with the threshold moved the second failure stops.
#   - `--try-again` (ADR-0041 S4, safe mode's Try Again from the security process; the opus review of a0df9c3e, MINOR-1): the
#     flag stays until the shell is confirmed active (written when missing, removed only if it is still the one noted), the
#     ledger is cleared, the start limit reset, the unit started and asked whether it is active, each step bounded; a run
#     killed in the reset or the start, a failed start, a unit not active after it, or a new loop's flag written meanwhile all
#     leave a flag; no runtime directory or a linked one does nothing; an unknown argument does nothing; the counter's own
#     path (no argument, the unit's) still never starts or resets anything; systemctl and timeout by absolute path; mutants:
#     the flag removed before the start, no active check, no identity check.
# The scratch copies run a stub systemctl: the script's absolute /usr/bin/systemctl is rewritten to it, and every copy is
# checked to name no real systemctl before it runs (the owner's own user manager is never asked).
set -euo pipefail
root=$(git -C "$(dirname "$0")" rev-parse --show-toplevel)
tmp=$(mktemp -d "${GRASSFIELD_TEST_TMP:-${TMPDIR:-/tmp}}/shell-failures.XXXXXX")
trap 'rm -rf "$tmp"' EXIT
fail=0
check() { if "$@"; then echo "PASS: $desc"; else echo "FAIL: $desc"; fail=1; fi; }
mkdir -p "$tmp/bin" "$tmp/lib" "$tmp/run"
# copy_script <source> <dest>: the script with its systemctl pointed at the stub; refused if any real one is left.
copy_script() {
  sed "s#/usr/bin/systemctl#$tmp/bin/systemctl#g" "$1" >"$2"
  chmod +x "$2"
  if grep -q "/usr/bin/systemctl" "$2" || grep -v "^ *#" "$2" | grep -qE "(^|[^/a-z])systemctl "; then
    echo "FAIL: $2 would run a real systemctl"
    exit 1
  fi
}
copy_script "$root/packaging/bin/grassfield-shell-failed" "$tmp/lib/grassfield-shell-failed"
cat >"$tmp/lib/session-gone" <<'SH'
#!/bin/sh
[ "${FAKE_GONE:-0}" = 1 ] && exit 0
exit 1
SH
cat >"$tmp/bin/systemctl" <<'SH'
#!/bin/sh
echo "systemctl $*" >>"$FAKE_LOG"
flag=${XDG_RUNTIME_DIR:-/nonexistent}/grassfield/shell-safe-mode
case " $* " in
  *" reset-failed "*)
    [ -n "${FAKE_RESET_SLEEP:-}" ] && sleep "$FAKE_RESET_SLEEP"
    ;;
  *" start "*)
    # Whether the flag was there when the start was asked (Try Again keeps it until the shell is confirmed).
    if [ -e "$flag" ]; then echo "flag-at-start=1" >>"$FAKE_LOG"; else echo "flag-at-start=0" >>"$FAKE_LOG"; fi
    [ -n "${FAKE_START_SLEEP:-}" ] && sleep "$FAKE_START_SLEEP"
    # A new loop's flag written meanwhile (the counter writes a new file and renames it).
    if [ "${FAKE_START_NEWFLAG:-0}" = 1 ]; then printf 'loop 9 3\n' >"$flag.x" && mv -f "$flag.x" "$flag"; fi
    [ "${FAKE_START_FAILS:-0}" = 1 ] && exit 5
    ;;
  *" is-active "*)
    [ "${FAKE_ACTIVE:-1}" = 1 ] || exit 3
    ;;
esac
[ "${FAKE_STOP_FAILS:-0}" = 1 ] && exit 1
exit 0
SH
# stat(1) as the script finds it (through PATH): the real one, unless a case makes it fail.
cat >"$tmp/bin/stat" <<'SH'
#!/bin/sh
[ "${FAKE_STAT_FAILS:-0}" = 1 ] && exit 1
exec /usr/bin/stat "$@"
SH
chmod +x "$tmp/lib/grassfield-shell-failed" "$tmp/lib/session-gone" "$tmp/bin/systemctl" "$tmp/bin/stat"
run() { # <now> [VAR=value...] -> exit code in $rc, stderr in $err; the ledger lives in $tmp/run/grassfield
  local now=$1
  rc=0
  shift
  err=$(env -i PATH="$tmp/bin:/usr/bin:/bin" XDG_RUNTIME_DIR="$tmp/run" FAKE_LOG="$tmp/log" GRASSFIELD_SHELL_FAIL_NOW="$now" "$@" \
    sh "$tmp/lib/grassfield-shell-failed" 2>&1 >/dev/null) || rc=$?
  return 0
}
run_real() { # no clock given: the script reads /proc/uptime itself
  local rc=0
  err=$(env -i PATH="$tmp/bin:/usr/bin:/bin" XDG_RUNTIME_DIR="$tmp/run" FAKE_LOG="$tmp/log" sh "$tmp/lib/grassfield-shell-failed" 2>&1 >/dev/null) || rc=$?
  return 0
}
ledger() { cat "$tmp/run/grassfield/shell-failures" 2>/dev/null | tr '\n' ' '; }
stops() { grep -c -x "systemctl --user stop grassfield-shell.service" "$tmp/log" 2>/dev/null || true; }
others() { grep -v -c -x "systemctl --user stop grassfield-shell.service" "$tmp/log" 2>/dev/null || true; }
fresh() { rm -rf "$tmp/run/grassfield" "$tmp/log"; : >"$tmp/log"; }

# 1. Three failures within the window: the third stops the shell, once, and writes the state.
fresh
run 1000; desc="the first failure counts (ledger: one line), stops nothing, exits 0"
check test "$rc" = 0 -a "$(ledger)" = "1000 " -a "$(stops)" = 0 -a ! -e "$tmp/run/grassfield/shell-safe-mode"
run 1005; desc="the second failure counts, stops nothing"
check test "$rc" = 0 -a "$(ledger)" = "1000 1005 " -a "$(stops)" = 0
run 1010; desc="the third failure within 10 minutes stops grassfield-shell.service once and writes the safe-mode state"
check test "$rc" = 0 -a "$(stops)" = 1 -a "$(cat "$tmp/run/grassfield/shell-safe-mode")" = "loop 1010 3"
desc="it runs nothing but that one systemctl stop (no start, no reset-failed, no kill)"
check test "$(others)" = 0
desc="the ledger and the state are the user's own files (0600, in a 0700 directory)"
check test "$(stat -c %a "$tmp/run/grassfield/shell-failures")" = 600 -a "$(stat -c %a "$tmp/run/grassfield/shell-safe-mode")" = 600 -a "$(stat -c %a "$tmp/run/grassfield")" = 700
# 2. Failures older than the window are forgotten.
fresh
run 0; run 300; run 700
desc="a failure 700 s after the first forgets it (window 600 s): two in the ledger, no stop"
check test "$(ledger)" = "300 700 " -a "$(stops)" = 0
run 800; desc="the next one is the third within the window: the stop"
check test "$(ledger)" = "300 700 800 " -a "$(stops)" = 1
fresh
run 0; run 300; run 600
desc="the window is inclusive: failures at 0, 300 and 600 s are three within 600 s, the stop"
check test "$(ledger)" = "0 300 600 " -a "$(stops)" = 1
fresh
run 0; run 300; run 601
desc="one second past the window the first failure is forgotten: no stop"
check test "$(ledger)" = "300 601 " -a "$(stops)" = 0
fresh
before=$(cut -d' ' -f1 /proc/uptime); before=${before%%.*}
run_real
after=$(cut -d' ' -f1 /proc/uptime); after=${after%%.*}
got=$(ledger); got=${got% }
desc="without a clock given the script reads /proc/uptime itself (the ledger holds the uptime in whole seconds)"
check bash -c '[[ $1 =~ ^[0-9]+$ ]] && (( $1 >= $2 && $1 <= $3 ))' _ "$got" "$before" "$after"
fresh
run 1; run 2; run 3 FAKE_STOP_FAILS=1
desc="a stop that fails is said in the journal (the restarts go on), the state file is still written"
check bash -c '[[ $1 == *"the stop of its unit failed"* ]]' _ "$err"
check test -e "$tmp/run/grassfield/shell-safe-mode"
fresh
run 1; run 2; run 3
desc="the journal line that says the restarts stopped comes after the stop succeeded"
check bash -c '[[ $1 == *"restarts stopped"* ]]' _ "$err"
# 3. A logout counts nothing.
fresh
run 1000; run 1005
run 1010 FAKE_GONE=1
desc="a failure while the compositor is certainly gone (a logout's exit 255) is not counted and stops nothing"
check test "$(ledger)" = "1000 1005 " -a "$(stops)" = 0
# 4. What it cannot read never stops the shell.
fresh
mkdir -p "$tmp/run/grassfield"
printf 'abc\n\n99999999999\n-5\n1000 extra\n' >"$tmp/run/grassfield/shell-failures"
run 1001; desc="garbage, empty, future and negative lines of the ledger are dropped (a trailing word is ignored, its number kept): two lines, no stop"
check test "$(ledger)" = "1000 1001 " -a "$(stops)" = 0
fresh
mkdir -p "$tmp/run/grassfield"
ln -s /etc/passwd "$tmp/run/grassfield/shell-failures"
run 1000; desc="a ledger that is a symlink is not read (replaced by a plain file with this failure only)"
check test ! -L "$tmp/run/grassfield/shell-failures" -a "$(ledger)" = "1000 " -a "$(stops)" = 0
fresh
run abc; desc="an unreadable clock counts nothing, stops nothing, exits 0 (the restarts go on)"
check test "$rc" = 0 -a "$(stops)" = 0 -a ! -e "$tmp/run/grassfield/shell-failures"
desc="an unreadable clock says so in the journal"
check bash -c '[[ $1 == *"cannot read the clock"* ]]' _ "$err"
fresh
err=$(env -i PATH="$tmp/bin:/usr/bin:/bin" FAKE_LOG="$tmp/log" GRASSFIELD_SHELL_FAIL_NOW=5 sh "$tmp/lib/grassfield-shell-failed" 2>&1 >/dev/null) || rc=$?
desc="without XDG_RUNTIME_DIR it counts nothing and stops nothing"
check bash -c '[[ $1 == *"no XDG_RUNTIME_DIR"* ]]' _ "$err"
check test "$(stops)" = 0
# 5. The window and the threshold are the unit's: 3 in 600 s by default, the test variables change them.
fresh
run 10 GRASSFIELD_SHELL_FAIL_COUNT=2; run 20 GRASSFIELD_SHELL_FAIL_COUNT=2
desc="a threshold of 2 stops at the second failure"
check test "$(stops)" = 1
fresh
run 10 GRASSFIELD_SHELL_FAIL_WINDOW=5; run 20 GRASSFIELD_SHELL_FAIL_WINDOW=5; run 30 GRASSFIELD_SHELL_FAIL_WINDOW=5
desc="a window of 5 s keeps one failure at a time: no stop"
check test "$(stops)" = 0 -a "$(ledger)" = "30 "
fresh
run 10 GRASSFIELD_SHELL_FAIL_COUNT=0 GRASSFIELD_SHELL_FAIL_WINDOW=abc; run 11 GRASSFIELD_SHELL_FAIL_COUNT=0 GRASSFIELD_SHELL_FAIL_WINDOW=abc
desc="nonsense values fall back to the defaults (3 in 600 s): two failures stop nothing"
check test "$(stops)" = 0 -a "$(ledger)" = "10 11 "
# 5b. Try Again (ADR-0041 S4): `--try-again`, run by the security process's safe-mode notice. The flag stays until the
# shell is confirmed active (the opus review of a0df9c3e, MINOR-1).
tryagain() { # [VAR=value...] -> exit code in $rc, stderr in $err
  rc=0
  err=$(env -i PATH="$tmp/bin:/usr/bin:/bin" XDG_RUNTIME_DIR="$tmp/run" FAKE_LOG="$tmp/log" "$@" sh "$tmp/lib/grassfield-shell-failed" --try-again 2>&1 >/dev/null) || rc=$?
  return 0
}
loop() { fresh; run 1; run 2; run 3; : >"$tmp/log"; }
flag=$tmp/run/grassfield/shell-safe-mode
loop
tryagain
desc="Try Again: exit 0, the failure ledger and the safe-mode flag are gone once the shell is active"
check test "$rc" = 0 -a ! -e "$tmp/run/grassfield/shell-failures" -a ! -e "$flag"
desc="Try Again: resets the start limit, starts the unit, asks whether it is active, as the user, nothing else (no stop)"
check test "$(grep -v '^flag-at-start=' "$tmp/log" | tr '\n' '|')" = "systemctl --user reset-failed grassfield-shell.service|systemctl --user start grassfield-shell.service|systemctl --user is-active --quiet grassfield-shell.service|"
desc="Try Again: the flag is still there while the start is asked (removed only once the shell is confirmed)"
check grep -qx "flag-at-start=1" "$tmp/log"
desc="Try Again: says it in the journal"
check bash -c '[[ $1 == *"grassfield-shell started"* ]]' _ "$err"
run 100; run 101
desc="Try Again: the next loop is counted from zero (two failures after it stop nothing)"
check test "$(ledger)" = "100 101 " -a "$(stops)" = 0
loop
inode=$(stat -c %i "$flag")
tryagain FAKE_START_FAILS=1
desc="Try Again whose start fails: exit 1, the same flag stays (never removed), the ledger is cleared"
check test "$rc" = 1 -a "$(stat -c %i "$flag" 2>/dev/null)" = "$inode" -a ! -e "$tmp/run/grassfield/shell-failures"
desc="Try Again whose start fails: the journal says the flag stays"
check bash -c '[[ $1 == *"did not start: the safe-mode flag stays"* ]]' _ "$err"
loop
tryagain FAKE_ACTIVE=0
desc="Try Again whose shell is not active after its start: exit 1, the flag stays"
check test "$rc" = 1 -a -f "$flag"
# MINOR-1's case: the run killed from outside (the caller's bound, the security unit restarting) in the start, then in the reset.
loop
rc=0
env -i PATH="$tmp/bin:/usr/bin:/bin" XDG_RUNTIME_DIR="$tmp/run" FAKE_LOG="$tmp/log" FAKE_START_SLEEP=30 timeout -k 1 2 sh "$tmp/lib/grassfield-shell-failed" --try-again >/dev/null 2>&1 || rc=$?
desc="Try Again killed during the start (outer bound): the flag is still there, so the notice comes back while the unit is down"
check test "$rc" = 124 -a -f "$flag"
loop
rc=0
env -i PATH="$tmp/bin:/usr/bin:/bin" XDG_RUNTIME_DIR="$tmp/run" FAKE_LOG="$tmp/log" FAKE_RESET_SLEEP=30 timeout -k 1 2 sh "$tmp/lib/grassfield-shell-failed" --try-again >/dev/null 2>&1 || rc=$?
desc="Try Again killed during the reset (outer bound): the flag is still there"
check test "$rc" = 124 -a -f "$flag"
loop
start=$SECONDS
tryagain FAKE_RESET_SLEEP=60
desc="Try Again with a reset that hangs: its own bound (5 s) ends it and the start goes on, within the caller's 40 s"
check test "$rc" = 0 -a $((SECONDS - start)) -le 12 -a ! -e "$flag"
fresh
mkdir -p "$tmp/run/grassfield"
tryagain FAKE_START_FAILS=1
desc="Try Again with no flag (a unit at its start limit, ADR-0056 D-10) whose start fails: a flag is written and stays"
check test "$rc" = 1 -a -f "$flag" -a "$(cat "$flag")" = "try-again" -a "$(stat -c %a "$flag")" = 600
fresh
mkdir -p "$tmp/run/grassfield"
tryagain
desc="Try Again with no flag whose start works: no flag is left"
check test "$rc" = 0 -a ! -e "$flag"
loop
tryagain FAKE_START_NEWFLAG=1
desc="Try Again during which a new loop wrote its flag: that flag is kept (only the one noted is removed)"
check test "$rc" = 0 -a "$(cat "$flag" 2>/dev/null)" = "loop 9 3"
desc="Try Again during which a new loop wrote its flag: the journal says it stays"
check bash -c '[[ $1 == *"a new safe-mode flag was written meanwhile"* ]]' _ "$err"
loop
tryagain FAKE_STAT_FAILS=1
desc="Try Again whose stat fails (the flag's identity unreadable, the delta review of b67472da, NIT): the shell is started, the flag stays as not the same file, and the journal says so"
check bash -c '[ "$1" = 0 ] && [ -f "$2" ] && [[ $3 == *"identity could not be read: it stays"* ]]' _ "$rc" "$flag" "$err"
fresh
rc=0
err=$(env -i PATH="$tmp/bin:/usr/bin:/bin" FAKE_LOG="$tmp/log" sh "$tmp/lib/grassfield-shell-failed" --try-again 2>&1 >/dev/null) || rc=$?
desc="Try Again without XDG_RUNTIME_DIR does nothing (exit 1, no systemctl): it could not keep a flag"
check bash -c '[ "$1" = 1 ] && [ ! -s "$2" ] && [[ $3 == *"no usable runtime directory"* ]]' _ "$rc" "$tmp/log" "$err"
fresh
mkdir -p "$tmp/elsewhere"
printf 'keep\n' >"$tmp/elsewhere/shell-safe-mode"
ln -s "$tmp/elsewhere" "$tmp/run/grassfield"
tryagain
desc="Try Again with a linked runtime directory does nothing (exit 1, no systemctl, nothing removed through the link)"
check test "$rc" = 1 -a ! -s "$tmp/log" -a "$(cat "$tmp/elsewhere/shell-safe-mode")" = keep
rm -f "$tmp/run/grassfield"
fresh
rc=0
err=$(env -i PATH="$tmp/bin:/usr/bin:/bin" XDG_RUNTIME_DIR="$tmp/run" FAKE_LOG="$tmp/log" GRASSFIELD_SHELL_FAIL_NOW=5 sh "$tmp/lib/grassfield-shell-failed" --tryagain 2>&1 >/dev/null) || rc=$?
desc="an unknown argument does nothing (exit 2, no ledger, no systemctl)"
check bash -c '[ "$1" = 2 ] && [ ! -s "$2" ] && [ ! -e "$3" ]' _ "$rc" "$tmp/log" "$tmp/run/grassfield/shell-failures"

# 6. Static: the unit starts this script through OnFailure= of the shell, hardened, installed by the PKGBUILD.
u=$root/packaging/systemd/grassfield-shell-failed.service
desc="grassfield-shell.service names the counter as its only OnFailure= (ADR-0041 S2: Omarchy's sleep lock is armed by grassfield-security.service, which holds the inhibitor), with the SQ-2 A backstop (10 starts in 5 minutes)"
check bash -c 'grep -qx "OnFailure=grassfield-shell-failed.service" "$1" && grep -qx "StartLimitIntervalSec=300" "$1" && grep -qx "StartLimitBurst=10" "$1" && grep -qx "Restart=always" "$1"' _ "$root/packaging/systemd/grassfield-shell.service"
desc="the counter's unit is a oneshot of the Grassfield session only, hardened, with the shared runtime directory"
check bash -c 'grep -qx "Type=oneshot" "$1" && grep -qx "ConditionEnvironment=GRASSFIELD_SESSION=1" "$1" && grep -qx "ExecStart=/usr/lib/grassfield/grassfield-shell-failed" "$1" && grep -qx "RuntimeDirectory=grassfield" "$1" && grep -qx "RuntimeDirectoryPreserve=yes" "$1" && grep -qx "NoNewPrivileges=yes" "$1" && grep -qx "ProtectSystem=strict" "$1" && grep -qx "PrivateNetwork=yes" "$1" && grep -qx "SystemCallFilter=@system-service" "$1" && grep -qx "CapabilityBoundingSet=" "$1" && ! grep -q "^Restart=" "$1"' _ "$u"
desc="the unit clears the script's three test variables, so the session never honours them (opus review of b1d826b, finding 3)"
check grep -qx "UnsetEnvironment=GRASSFIELD_SHELL_FAIL_WINDOW GRASSFIELD_SHELL_FAIL_COUNT GRASSFIELD_SHELL_FAIL_NOW" "$u"
desc="the shell unit keeps systemd's RestartMode=normal (a RestartMode=direct would skip 'failed' and OnFailure= would never run)"
check bash -c '! grep -q "^RestartMode=" "$1" || grep -qx "RestartMode=normal" "$1"' _ "$root/packaging/systemd/grassfield-shell.service"
desc="the counter is reachable only through OnFailure= of the shell: no [Install] section, not in the autostart, named by no other unit or drop-in"
check bash -c '! grep -q "^\[Install\]" "$1" && ! grep -q "WantedBy=\|RequiredBy=" "$1" && ! grep -q "shell-failed" "$2" && [ "$(grep -l "grassfield-shell-failed" "$3"/systemd/*.service "$3"/systemd/*.d/* 2>/dev/null | grep -v "grassfield-shell-failed.service$" | tr "\n" " ")" = "$3/systemd/grassfield-shell.service " ]' _ "$u" "$root/config/hypr/grassfield/autostart.lua" "$root/packaging"
desc="the sandbox keeps what the stop needs (AF_UNIX for the manager's private socket) and pins ProtectHome=read-only (opus review U6)"
check bash -c 'grep -qx "RestrictAddressFamilies=AF_UNIX" "$1" && grep -qx "ProtectHome=read-only" "$1" && grep -q "block that request" "$1"' _ "$u"
desc="the PKGBUILD installs the unit, the script (from packaging/bin) and session-gone next to it"
check bash -c 'grep -q "for unit in .*shell-failed" "$1" && grep -q "packaging/bin\" -maxdepth 1 -type f -exec install -m755 -t \"\$pkgdir/usr/lib/grassfield/\"" "$1" && grep -q "packaging/systemd/session-gone\" \"\$pkgdir/usr/lib/grassfield/session-gone\"" "$1"' _ "$root/packaging/arch/PKGBUILD"
# The counter's own path is the script without its `--try-again` block (from its `if` line to the first `fi` at the start of
# a line): there, no start, reset-failed, kill, restart, unlock or qs; the block itself starts and resets the shell's unit
# with `systemctl --user` and nothing else.
awk '/^if \[ "\$\{1:-\}" = "--try-again" \]; then$/ { skip = 1 } !skip { print } skip && /^fi$/ { skip = 0 }' "$root/packaging/bin/grassfield-shell-failed" >"$tmp/counter-path"
awk '/^if \[ "\$\{1:-\}" = "--try-again" \]; then$/ { on = 1 } on { print } on && /^fi$/ { exit }' "$root/packaging/bin/grassfield-shell-failed" >"$tmp/try-again-path"
desc="the script asks session-gone next to itself and, on the counter's path, never calls start, reset-failed, kill, unlock or qs"
check bash -c '[ -s "$2" ] && grep -q "\$(dirname \"\$0\")/session-gone" "$1" && ! grep -v "^#" "$1" | grep -q -E "systemctl --user (start|reset-failed|kill|restart)|unlock|\bqs\b"' _ "$tmp/counter-path" "$tmp/try-again-path"
desc="the --try-again block runs exactly one reset-failed, one start and one is-active of grassfield-shell.service (as the user), each bounded by /usr/bin/timeout, and no stop, kill, restart, unlock or qs"
check bash -c '[ "$(grep -c -E "^  (if ! )?/usr/bin/timeout -k [0-9]+ [0-9]+ /usr/bin/systemctl --user (reset-failed|start|is-active --quiet) grassfield-shell.service" "$1")" = 3 ] && [ "$(grep -o -E "systemctl --user [a-z-]+" "$1" | sort -u | tr "\n" " ")" = "systemctl --user is-active systemctl --user reset-failed systemctl --user start " ] && ! grep -q -E "unlock|\bqs\b|\bkill\b|session-gone" "$1"' _ "$tmp/try-again-path"
desc="systemctl and timeout only by absolute path in the whole script (the review's NIT)"
check bash -c '! grep -v "^ *#" "$1" | grep -qE "(^|[^/a-z-])(systemctl|timeout) "' _ "$root/packaging/bin/grassfield-shell-failed"
desc="the unit runs the counter with no argument (Try Again is the security process's, never the unit's)"
check grep -qx "ExecStart=/usr/lib/grassfield/grassfield-shell-failed" "$u"
# 7. Mutants: each must change the decisions.
mutant() { # <name> <sed expression>
  sed "$2" "$root/packaging/bin/grassfield-shell-failed" >"$tmp/lib/mutant-src-$1"
  cmp -s "$tmp/lib/mutant-src-$1" "$root/packaging/bin/grassfield-shell-failed" && { echo "FAIL: mutant $1 did not change the script"; fail=1; }
  copy_script "$tmp/lib/mutant-src-$1" "$tmp/lib/mutant-$1"
  return 0
}
runm() { # <name> <now> [VAR=value...]
  local name=$1 now=$2 rc=0
  shift 2
  env -i PATH="$tmp/bin:/usr/bin:/bin" XDG_RUNTIME_DIR="$tmp/run" FAKE_LOG="$tmp/log" GRASSFIELD_SHELL_FAIL_NOW="$now" "$@" sh "$tmp/lib/mutant-$name" >/dev/null 2>&1 || rc=$?
  return 0
}
mutant no-gone 's|^if "$(dirname "$0")/session-gone"; then|if false; then|'
fresh; runm no-gone 1 FAKE_GONE=1; runm no-gone 2 FAKE_GONE=1; runm no-gone 3 FAKE_GONE=1
desc="mutant: without the session-gone check a logout counts and the third stops (the real script counts nothing)"
check test "$(stops)" = 1
mutant threshold 's|if \[ "$count" -lt "$count_max" \]; then|if [ "$count" -lt $((count_max - 1)) ]; then|'
fresh; runm threshold 1; runm threshold 2
desc="mutant: with the threshold moved down the second failure stops (the real script needs the third)"
check test "$(stops)" = 1
mutant no-prune 's|now - \$1 <= w|1|'
fresh; runm no-prune 0; runm no-prune 300; runm no-prune 700
desc="mutant: without the window the failure of 700 s ago still counts and the third stops (the real script forgets it)"
check test "$(stops)" = 1
tryagainm() { # <name> [VAR=value...]
  local name=$1
  shift
  env -i PATH="$tmp/bin:/usr/bin:/bin" XDG_RUNTIME_DIR="$tmp/run" FAKE_LOG="$tmp/log" "$@" sh "$tmp/lib/mutant-$name" --try-again >/dev/null 2>&1 || true
}
mutant flag-first 's|^  noted=$(stat -c %i -- "$flag" 2>/dev/null)$|  rm -f "$flag"; noted=|'
loop
env -i PATH="$tmp/bin:/usr/bin:/bin" XDG_RUNTIME_DIR="$tmp/run" FAKE_LOG="$tmp/log" FAKE_START_SLEEP=30 timeout -k 1 2 sh "$tmp/lib/mutant-flag-first" --try-again >/dev/null 2>&1 || true
desc="mutant: the flag removed before the start is caught (killed in the start, no flag is left)"
check test ! -e "$tmp/run/grassfield/shell-safe-mode"
mutant no-active-check 's|^  if ! /usr/bin/timeout -k 1 5 /usr/bin/systemctl --user is-active --quiet grassfield-shell.service; then$|  if false; then|'
loop; tryagainm no-active-check FAKE_ACTIVE=0
desc="mutant: without the active check the flag goes while the shell is not running (caught)"
check test ! -e "$tmp/run/grassfield/shell-safe-mode"
mutant no-identity 's|^  elif \[ "$current" = "$noted" \]; then$|  elif true; then|'
loop; tryagainm no-identity FAKE_START_NEWFLAG=1
desc="mutant: without the identity check a new loop's flag is removed (caught)"
check test ! -e "$tmp/run/grassfield/shell-safe-mode"
exit "$fail"
