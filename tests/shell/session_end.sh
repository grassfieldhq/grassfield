#!/usr/bin/env bash
# GF-025: Log Out, Restart and Shut Down ask every application to close first and never end the session over an
# application that kept its window open (it might hold unsaved work). packaging/bin/grassfield-session-end against fake
# hyprctl, notify-send, uwsm and systemctl: no compositor, no session, nothing real is touched.
set -euo pipefail
export LC_ALL=C; unset GRASSFIELD_LANG LC_MESSAGES  # the helpers translate by locale: the assertions read the English source
root=$(git -C "$(dirname "$0")" rev-parse --show-toplevel)
tmp=$(mktemp -d "${GRASSFIELD_TEST_TMP:-${TMPDIR:-/tmp}}/session-end.XXXXXX")
trap 'rm -rf "$tmp"' EXIT
fail=0
check() { if "$@"; then echo "PASS: $desc"; else echo "FAIL: $desc"; fail=1; fi; }

bin=$tmp/bin
mkdir -p "$bin" "$tmp/state/omarchy"
cat >"$bin/hyprctl" <<'PY'
#!/usr/bin/python3 -I
import json, os, re, sys
d = os.environ["FAKE_DIR"]
args = sys.argv[1:]
clients = lambda: json.load(open(d + "/clients.json"))
if args == ["-j", "clients"]:
    n = int(open(d + "/clients.calls").read() or 0) + 1 if os.path.exists(d + "/clients.calls") else 1
    open(d + "/clients.calls", "w").write(str(n))
    if os.path.exists(d + "/compositor-down") or str(n) in os.environ.get("FAKE_FAIL_CALLS", "").split():
        sys.exit(1)
    # A scripted answer per call (seq/N.json; a call past the last file repeats the last one), else the live client list.
    seq = sorted(int(f[:-5]) for f in os.listdir(d + "/seq") if f.endswith(".json")) if os.path.isdir(d + "/seq") else []
    if seq:
        use = max([i for i in seq if i <= n] or [seq[0]])
        sys.stdout.write(open(d + "/seq/%d.json" % use).read())
        sys.exit(0)
    print(json.dumps(clients()))
elif args and args[0] == "dispatch":
    open(d + "/hyprctl.log", "a").write(args[1] + "\n")
    if args[1] == "hl.dsp.exit()" and os.environ.get("FAKE_EXIT_FAIL"):
        sys.exit(1)
    m = re.search(r'address:(0x[0-9a-f]+)', args[1])
    if m:
        a = m.group(1)
        refuse = os.environ.get("FAKE_REFUSE", "").split()
        dialog = os.environ.get("FAKE_DIALOG", "").split()
        cl = clients()
        if a in dialog:  # the application answers with its own "Save changes?" window and keeps the document window
            if not any(c["address"] == "0x9" for c in cl):
                cl.append({"address": "0x9", "class": "save-dialog", "title": "Save changes?"})
        elif a not in refuse:
            cl = [c for c in cl if c["address"] != a]
        json.dump(cl, open(d + "/clients.json", "w"))
PY
for name in uwsm systemctl gdbus; do   # FAKE_FAIL_<name>: that helper fails
  printf '#!/bin/sh\necho "%s $*" >>"$FAKE_DIR/calls.log"\n[ -z "$FAKE_FAIL_%s" ] || exit 1\n' "$name" "$name" >"$bin/$name"
done
# The shell's IPC (ADR-0040 ID-10, the exit cover). Always this stand-in: the real `qs` would reach the session's own shell.
cat >"$bin/qs" <<'SH'
#!/bin/sh
echo "qs $* manifest=${QS_MANIFEST:-}" >>"$FAKE_DIR/calls.log"
[ -z "$FAKE_QS_FAIL" ] || exit 1
[ -z "$FAKE_QS_HANG" ] || exec sleep 30
case "$*" in
  *" session cover") printf '%s\n' "${FAKE_QS_ANSWER:-400}" ;;
  *" session lift") echo ok ;;
esac
SH
cat >"$bin/notify-send" <<'SH'
#!/bin/sh
echo "notify-send $*" >>"$FAKE_DIR/calls.log"
[ -z "$FAKE_NOTIFY_FAIL" ] || exit 1
case " $* " in *" -p "*) echo 42 ;; esac            # -p prints the notification id first, then the chosen action
[ -z "$FAKE_NOTIFY_HANG" ] || sleep 30               # nobody answers
n=$(($(cat "$FAKE_DIR/notify.count" 2>/dev/null || echo 0) + 1)); echo "$n" >"$FAKE_DIR/notify.count"
if [ -n "$FAKE_NOTIFY_ONCE" ] && [ "$n" -gt 1 ]; then exit 0; fi   # the user answers only the first notice
printf '%s\n' "${FAKE_NOTIFY_ANSWER:-}"
SH
chmod +x "$bin"/*

run() { # run <clients-json> <args...>; env FAKE_* passes through; prints the exit status in $status
  : >"$tmp/calls.log"; : >"$tmp/hyprctl.log"; rm -rf "$tmp/compositor-down" "$tmp/clients.calls" "$tmp/seq" "$tmp/notify.count"
  printf '%s' "$1" >"$tmp/clients.json"; shift
  if [[ -n ${SEQ:-} ]]; then mkdir -p "$tmp/seq"; i=0; for j in $SEQ; do i=$((i + 1)); printf '%s' "$j" >"$tmp/seq/$i.json"; done; fi
  status=0
  FAKE_DIR=$tmp PATH="$bin:/usr/bin:/bin" XDG_RUNTIME_DIR=$tmp XDG_STATE_HOME=$tmp/state GRASSFIELD_SESSION_END_TIMEOUT=${SESSION_END_TIMEOUT:-1} GRASSFIELD_SESSION_END_GRACE=0 \
    python3 -I "$root/packaging/bin/grassfield-session-end" "$@" >"$tmp/out.log" 2>&1 || status=$?
}
two='[{"address":"0x1","class":"firefox","title":"a"},{"address":"0x2","class":"kate","title":"b"}]'
calls() { cat "$tmp/calls.log"; }

desc="compliant applications: every window gets a close request, then uwsm stop ends the session"
run "$two" logout
check bash -c '[[ $(grep -c "window.close" "$1/hyprctl.log") == 2 ]] && grep -q "address:0x1" "$1/hyprctl.log" && grep -q "address:0x2" "$1/hyprctl.log" && grep -qx "uwsm stop" "$1/calls.log" && [[ $2 == 0 ]]' _ "$tmp" "$status"
desc="the session is not ended before the windows are gone (no notice either)"
check bash -c '! grep -q notify-send "$1/calls.log"' _ "$tmp"

desc="an application that keeps its window: nothing is ended, a notice names it and offers Log Out Anyway, exit 3"
FAKE_REFUSE="0x2" run "$two" logout
check bash -c 'grep -q "^notify-send .*force=Log Out Anyway" "$1/calls.log" && grep -q "kate" "$1/calls.log" && ! grep -q "uwsm stop" "$1/calls.log" && [[ $2 == 3 ]]' _ "$tmp" "$status"

desc="the user chooses 'Log Out Anyway': the session ends"
FAKE_REFUSE="0x2" FAKE_NOTIFY_ANSWER=force run "$two" logout
check bash -c 'grep -qx "uwsm stop" "$1/calls.log" && [[ $2 == 0 ]]' _ "$tmp" "$status"

desc="a window the application opens meanwhile (its Save sheet) is never closed on the user's behalf, and blocks the restart"
FAKE_DIALOG="0x2" run "$two" restart
check bash -c '[[ $(grep -c "window.close" "$1/hyprctl.log") == 2 ]] && ! grep -q "0x9" "$1/hyprctl.log" && grep -q "save-dialog" "$1/calls.log" && ! grep -q "systemctl" "$1/calls.log" && [[ $2 == 3 ]]' _ "$tmp" "$status"

desc="restart: systemctl reboot, and Omarchy's reboot-required markers are cleared (other state is kept)"
touch "$tmp/state/omarchy/reboot-required" "$tmp/state/omarchy/restart-foo-required" "$tmp/state/omarchy/keep"
run '[]' restart
check bash -c 'grep -qx "systemctl reboot --no-wall" "$1/calls.log" && [[ ! -e "$1/state/omarchy/reboot-required" && ! -e "$1/state/omarchy/restart-foo-required" && -e "$1/state/omarchy/keep" ]]' _ "$tmp"

desc="SS-07: systemctl refuses the restart: Omarchy's reboot-required markers stay (the restart is still owed)"
touch "$tmp/state/omarchy/reboot-required" "$tmp/state/omarchy/restart-foo-required"
FAKE_FAIL_systemctl=1 run '[]' restart
check bash -c 'grep -qx "systemctl reboot --no-wall" "$1/calls.log" && [[ -e "$1/state/omarchy/reboot-required" && -e "$1/state/omarchy/restart-foo-required" && $2 == 4 ]]' _ "$tmp" "$status"
rm -f "$tmp/state/omarchy/reboot-required" "$tmp/state/omarchy/restart-foo-required"

desc="shutdown: systemctl poweroff"
run '[]' shutdown
check grep -qx "systemctl poweroff --no-wall" "$tmp/calls.log"

desc="--force ends the session at once, closing nothing"
FAKE_REFUSE="0x2" run "$two" logout --force
check bash -c '[[ ! -s "$1/hyprctl.log" ]] && grep -qx "uwsm stop" "$1/calls.log" && [[ $2 == 0 ]]' _ "$tmp" "$status"

desc="an address that is not hexadecimal never reaches the Lua expression"
FAKE_REFUSE="0x2" run '[{"address":"0x1\"});os.exit()--","class":"x","title":"y"}]' logout --force
check bash -c '[[ ! -s "$1/hyprctl.log" ]]' _ "$tmp"
run '[{"address":"0x1\"});os.exit()--","class":"x","title":"y"}]' logout
check bash -c '[[ ! -s "$1/hyprctl.log" ]]' _ "$tmp"

desc="an address ending in a newline never reaches the Lua expression either (the regex's \$ matched before it; tests/fuzz/fuzz_helpers.py session-end, seed 1, iteration 19129)"
run '[{"address":"0x1\n","class":"x","title":"y"}]' logout
check bash -c '[[ ! -s "$1/hyprctl.log" ]]' _ "$tmp"

desc="an address is at most 16 hex digits (a 64-bit pointer): 16 digits are closed, 17 never reach the Lua expression"
run '[{"address":"0xffffffffffffffff","class":"x","title":"y"}]' logout
check bash -c 'grep -q "address:0xffffffffffffffff" "$1/hyprctl.log" && grep -qx "uwsm stop" "$1/calls.log" && [[ $2 == 0 ]]' _ "$tmp" "$status"
run '[{"address":"0x1ffffffffffffffff","class":"x","title":"y"}]' logout
check bash -c '[[ ! -s "$1/hyprctl.log" ]]' _ "$tmp"

desc="GF-025 review: ONE failed window query while waiting is not 'no windows': it is retried, the window is still there, nothing is ended"
FAKE_REFUSE="0x1" FAKE_FAIL_CALLS="2" run '[{"address":"0x1","class":"editor","title":"Save changes?"}]' logout
check bash -c '! grep -q "uwsm stop" "$1/calls.log" && grep -q "^notify-send .*editor" "$1/calls.log" && [[ $2 == 3 ]] && [[ $(cat "$1/clients.calls") -ge 3 ]]' _ "$tmp" "$status"

desc="a failed FIRST query is retried too: the window is found and closed, the session ends only after it is gone"
# The timeout only bounds the wait for the retries: the run ends as soon as the window is gone, so a wide one costs
# nothing at normal load and holds at load 35 (the integrator's merge review of #62).
FAKE_FAIL_CALLS="1 2" SESSION_END_TIMEOUT=15 run '[{"address":"0x1","class":"editor","title":"d"}]' logout
check bash -c 'grep -q "address:0x1" "$1/hyprctl.log" && grep -qx "uwsm stop" "$1/calls.log" && [[ $2 == 0 ]]' _ "$tmp" "$status"

desc="no compositor to ask, ever: nothing is closed or ended, a notice says the list could not be read (exit 3)"
: >"$tmp/calls.log"; : >"$tmp/compositor-down"; rm -f "$tmp/clients.calls"; printf '[]' >"$tmp/clients.json"; status=0
FAKE_DIR=$tmp PATH="$bin:/usr/bin:/bin" XDG_RUNTIME_DIR=$tmp XDG_STATE_HOME=$tmp/state GRASSFIELD_SESSION_END_TIMEOUT=1 GRASSFIELD_SESSION_END_GRACE=0 python3 -I "$root/packaging/bin/grassfield-session-end" shutdown >/dev/null 2>&1 || status=$?
check bash -c '! grep -q "systemctl" "$1/calls.log" && grep -q "^notify-send .*could not be read" "$1/calls.log" && [[ $2 == 3 ]]' _ "$tmp" "$status"

desc="...and the user's own 'Shut Down Anyway' is honoured"
: >"$tmp/calls.log"; status=0
FAKE_NOTIFY_ANSWER=force FAKE_DIR=$tmp PATH="$bin:/usr/bin:/bin" XDG_RUNTIME_DIR=$tmp XDG_STATE_HOME=$tmp/state GRASSFIELD_SESSION_END_TIMEOUT=1 GRASSFIELD_SESSION_END_GRACE=0 python3 -I "$root/packaging/bin/grassfield-session-end" shutdown >/dev/null 2>&1 || status=$?
check bash -c 'grep -qx "systemctl poweroff --no-wall" "$1/calls.log" && [[ $2 == 0 ]]' _ "$tmp" "$status"

desc="GF-025 review: a second run while one waits exits quietly and touches nothing (it would answer the Save sheet with Cancel)"
( flock "$tmp/grassfield-session-end.lock" sleep 6 ) &
holder=$!
for _ in $(seq 50); do flock -n "$tmp/grassfield-session-end.lock" true || break; sleep 0.1; done   # until the holder has it, at most 5 s
FAKE_REFUSE="0x2" run "$two" logout
check bash -c '[[ $2 == 0 ]] && [[ ! -s "$1/calls.log" ]] && [[ ! -s "$1/hyprctl.log" ]]' _ "$tmp" "$status"
wait "$holder" || true

desc="without notify-send the blocked logout still shows a notice through the shell's notification service (gdbus), ends nothing"
FAKE_NOTIFY_FAIL=1 FAKE_REFUSE="0x2" run "$two" logout
check bash -c 'grep -q "^gdbus call --session --dest org.freedesktop.Notifications .*kate" "$1/calls.log" && ! grep -q "uwsm stop" "$1/calls.log" && [[ $2 == 3 ]]' _ "$tmp" "$status"

A='[{"address":"0x1","class":"editor","title":"doc"}]'
SAVE='[{"address":"0x9","class":"editor","title":"Save_changes?"}]'
desc="GF-025 review M1: window list A, then ONE empty list, then a Save sheet: the session is not ended (two empty lists in a row are needed)"
SEQ="$A [] $SAVE" run "$A" logout
check bash -c '! grep -q "uwsm stop" "$1/calls.log" && grep -q "^notify-send .*editor" "$1/calls.log" && [[ $2 == 3 ]]' _ "$tmp" "$status"
desc="GF-025 review M1: A, [], [], then a Save sheet during the grace: the last look stops the logout"
SEQ="$A [] [] $SAVE" run "$A" logout
check bash -c '! grep -q "uwsm stop" "$1/calls.log" && grep -q "^notify-send .*editor" "$1/calls.log" && [[ $2 == 3 ]]' _ "$tmp" "$status"
desc="GF-025 review M1: A, then empty lists for good: the session ends"
SEQ="$A []" run "$A" logout
check bash -c 'grep -qx "uwsm stop" "$1/calls.log" && [[ $2 == 0 ]]' _ "$tmp" "$status"
desc="a JSON list of non-objects ([1]) is not 'no windows': unknown, nothing is ended"
SEQ="[1]" run "[1]" logout
check bash -c '! grep -q "uwsm stop" "$1/calls.log" && grep -q "^notify-send .*could not be read" "$1/calls.log" && [[ $2 == 3 ]]' _ "$tmp" "$status"
desc="a timeout of nan or inf is refused (the previous value stays): the run ends instead of waiting for ever with the lock held"
FAKE_REFUSE="0x2" run "$two" logout --timeout nan --timeout inf
check bash -c '[[ $2 == 3 ]]' _ "$tmp" "$status"
desc="the 'Anyway' notice is closed by id (CloseNotification 42) when the user dismissed it: no stale button is left"
FAKE_REFUSE="0x2" run "$two" logout
check grep -q "^gdbus call .*org.freedesktop.Notifications.CloseNotification 42" "$tmp/calls.log"
desc="...when the user pressed it..."
FAKE_REFUSE="0x2" FAKE_NOTIFY_ANSWER=force run "$two" logout
check grep -q "^gdbus call .*org.freedesktop.Notifications.CloseNotification 42" "$tmp/calls.log"
desc="...and when nobody answered before the wait ran out (the logout is cancelled, exit 3)"
FAKE_NOTIFY_HANG=1 GRASSFIELD_SESSION_END_ASK_TIMEOUT=2 FAKE_REFUSE="0x2" run "$two" logout
check bash -c 'grep -q "CloseNotification 42" "$1/calls.log" && ! grep -q "uwsm stop" "$1/calls.log" && [[ $2 == 3 ]]' _ "$tmp" "$status"

desc="GF-025 review major 2: after the user's own 'Anyway' no last look and no second notice: the session ends on one click, one notice"
FAKE_REFUSE="0x2" FAKE_NOTIFY_ANSWER=force FAKE_NOTIFY_ONCE=1 run "$two" logout
check bash -c 'grep -qx "uwsm stop" "$1/calls.log" && [[ $(grep -c "^notify-send" "$1/calls.log") == 1 ]] && [[ $2 == 0 ]]' _ "$tmp" "$status"
desc="...also when the list could not be read at all (unknown, then Anyway)"
FAKE_NOTIFY_ANSWER=force FAKE_NOTIFY_ONCE=1 FAKE_FAIL_CALLS="1 2 3 4 5 6 7 8 9 10 11 12" run "$two" logout
check bash -c 'grep -qx "uwsm stop" "$1/calls.log" && [[ $(grep -c "^notify-send" "$1/calls.log") == 1 ]] && [[ $2 == 0 ]]' _ "$tmp" "$status"
desc="GF-025 review minor 3: a timeout of 0 with lists A, [], [] confirms the empty list twice before it ends; A, [], Save does not"
SESSION_END_TIMEOUT=0 SEQ="$A [] []" run "$A" logout
check bash -c 'grep -qx "uwsm stop" "$1/calls.log" && [[ $2 == 0 ]]' _ "$tmp" "$status"
SESSION_END_TIMEOUT=0 SEQ="$A [] $SAVE" run "$A" logout
check bash -c '! grep -q "uwsm stop" "$1/calls.log" && [[ $2 == 3 ]]' _ "$tmp" "$status"
desc="GF-025 review: timeout 0 with A, [], [], Save: the second empty list confirms, the last look after the grace sees the Save sheet (a revert of the deadline fix ends the session here)"
SESSION_END_TIMEOUT=0 SEQ="$A [] [] $SAVE" run "$A" logout
check bash -c '! grep -q "uwsm stop" "$1/calls.log" && grep -q "^notify-send .*editor" "$1/calls.log" && [[ $2 == 3 ]]' _ "$tmp" "$status"
desc="GF-025 review: the list is known at first, then unknown for the whole wait, then the user chooses Anyway: one notice saying the list could not be read, the session ends"
FAKE_NOTIFY_ANSWER=force FAKE_NOTIFY_ONCE=1 FAKE_FAIL_CALLS="2 3 4 5 6 7 8 9 10 11 12 13 14" run "$A" logout
check bash -c 'grep -qx "uwsm stop" "$1/calls.log" && [[ $(grep -c "^notify-send" "$1/calls.log") == 1 ]] && grep -q "^notify-send .*could not be read" "$1/calls.log" && [[ $2 == 0 ]]' _ "$tmp" "$status"
desc="GF-025 review minor 5: a window with a non-text address, class or title is an unknown list: a notice, no crash, nothing ended"
for bad in '[{"address":5,"class":"x","title":"y"}]' '[{"address":"0x1","class":["a"],"title":"y"}]' '[{"address":"0x1","class":"x","title":{"a":1}}]'; do
  SEQ="$bad" run "$bad" logout
  check bash -c '! grep -q "uwsm stop" "$1/calls.log" && grep -q "^notify-send .*could not be read" "$1/calls.log" && [[ $2 == 3 ]] && ! grep -q Traceback "$1/out.log"' _ "$tmp" "$status"
done

desc="an unknown action is refused (exit 2) and ends nothing"
run '[]' hibernate
check bash -c '[[ $2 == 2 ]] && [[ ! -s "$1/calls.log" ]]' _ "$tmp" "$status"

# ADR-0040 ID-10: the exit cover. The shell's instance is called by its path with Quickshell's option variables cleared.
cover='qs ipc -p /usr/share/grassfield/shell call session cover manifest='
lift='qs ipc -p /usr/share/grassfield/shell call session lift manifest='
desc="ID-10: once the windows are gone the shell's exit cover is asked for (a stray QS_MANIFEST cleared), then the session ends; nothing is lifted"
QS_MANIFEST=stray run "$two" logout
check bash -c 'c=$(grep -nx "$2" "$1/calls.log" | cut -d: -f1) && u=$(grep -nx "uwsm stop" "$1/calls.log" | cut -d: -f1) && [[ -n $c && -n $u && $c -lt $u ]] && ! grep -q "session lift" "$1/calls.log" && [[ $3 == 0 ]]' _ "$tmp" "$cover" "$status"
desc="...for Restart, Shut Down and --force too, and after the user's own 'Anyway'"
for args in restart shutdown "logout --force"; do
  # shellcheck disable=SC2086  # the action and its option
  run '[]' $args
  check bash -c 'grep -qx "$2" "$1/calls.log" && [[ $3 == 0 ]]' _ "$tmp" "$cover" "$status"
done
FAKE_REFUSE="0x2" FAKE_NOTIFY_ANSWER=force run "$two" logout
check bash -c 'grep -qx "$2" "$1/calls.log" && grep -qx "uwsm stop" "$1/calls.log" && [[ $3 == 0 ]]' _ "$tmp" "$cover" "$status"
desc="ID-10: no cover while the session is not ended (an application kept its window): nothing asked of the shell"
FAKE_REFUSE="0x2" run "$two" logout
check bash -c '! grep -q "^qs " "$1/calls.log" && [[ $2 == 3 ]]' _ "$tmp" "$status"
desc="ID-10: a shell that does not answer costs nothing: the session still ends, nothing to lift"
FAKE_QS_FAIL=1 run "$two" logout
check bash -c 'grep -qx "uwsm stop" "$1/calls.log" && ! grep -q "session lift" "$1/calls.log" && [[ $2 == 0 ]]' _ "$tmp" "$status"
desc="ID-10: uwsm stop fails, the compositor's own exit works: the session ends, the cover stays"
FAKE_FAIL_uwsm=1 run "$two" logout
check bash -c 'grep -qx "hl.dsp.exit()" "$1/hyprctl.log" && ! grep -q "session lift" "$1/calls.log" && [[ $2 == 0 ]]' _ "$tmp" "$status"
desc="ID-10: the session cannot be ended (uwsm stop and the compositor's exit both fail): the cover is lifted after it came up, exit 4"
FAKE_FAIL_uwsm=1 FAKE_EXIT_FAIL=1 run "$two" logout
check bash -c 'c=$(grep -nx "$2" "$1/calls.log" | cut -d: -f1) && l=$(grep -nx "$3" "$1/calls.log" | cut -d: -f1) && [[ -n $c && -n $l && $c -lt $l ]] && [[ $4 == 4 ]]' _ "$tmp" "$cover" "$lift" "$status"
desc="ID-10: systemctl refuses the restart: the cover is lifted, exit 4"
FAKE_FAIL_systemctl=1 run '[]' restart
check bash -c 'grep -qx "$2" "$1/calls.log" && [[ $3 == 4 ]]' _ "$tmp" "$lift" "$status"
desc="ID-10: the helper's bound on the cover, EXIT_WAIT, is session.exitWaitMs"
check python3 -I -c 'import json, re, sys
t = json.load(open(sys.argv[1]))["session"]["exitWaitMs"]["value"]
m = re.search(r"^EXIT_WAIT = ([0-9.]+)", open(sys.argv[2]).read(), re.M)
sys.exit(0 if m and round(float(m.group(1)) * 1000) == t else 1)' "$root/ui/tokens/tokens.json" "$root/packaging/bin/grassfield-session-end"
desc="ID-10: whatever the shell answers or however long it takes, the cover costs at most EXIT_WAIT (1 s) each: an answer of 999999 ms, a hung shell"
for env in FAKE_QS_ANSWER=999999 FAKE_QS_HANG=1; do
  start=$(date +%s%N)
  export "${env?}"
  run '[]' logout
  unset "${env%%=*}"
  took=$((($(date +%s%N) - start) / 1000000))
  check bash -c 'grep -qx "uwsm stop" "$1/calls.log" && [[ $2 == 0 ]] && (( $3 < 4000 ))' _ "$tmp" "$status" "$took"
done

desc="the shell routes Log Out, Restart and Shut Down through the helper (not systemctl or exit directly)"
check bash -c 'grep -q "endSession(\"logout\")" "$1" && grep -q "endSession(\"restart\")" "$1" && grep -q "endSession(\"shutdown\")" "$1" && ! grep -q "systemctl(\"reboot\")\|systemctl(\"poweroff\")" "$1"' _ "$root/shell/services/Power.qml"

exit $fail
