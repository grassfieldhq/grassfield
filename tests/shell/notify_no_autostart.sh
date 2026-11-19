#!/usr/bin/env bash
# SS-05 (security-session audit): the session helpers that post notifications never start a notification daemon by D-Bus
# activation. With no owner of org.freedesktop.Notifications (the shell starting or restarting, safe mode), notify-send or a
# call to the name would start any daemon that ships an activatable org.freedesktop.Notifications (mako, dunst), which would
# then hold the name the shell's own server needs. Each helper asks the bus first (a call the bus answers itself, which
# starts nothing) and sends nothing while no server is there:
#   grassfield-battery-watch   NameHasOwner before notify-send; a warning not sent is not counted as given (retried)
#   grassfield-migrate-notify  waits for the server with busctl --auto-start=no; none within its wait: nothing sent
# (grassfield-crash-watch and grassfield-session-end: tests/shell/crash_watch.sh, tests/shell/session_end.sh). Stubs only:
# no bus, no session. Plain shell test: PASS/FAIL lines, non-zero on failure.
set -euo pipefail
root=$(git -C "$(dirname "$0")" rev-parse --show-toplevel)
tmp=$(mktemp -d "${GRASSFIELD_TEST_TMP:-${TMPDIR:-/tmp}}/notify-autostart.XXXXXX")
trap 'rm -rf "$tmp"' EXIT
fail=0
check() { if "$@"; then echo "PASS: $desc"; else echo "FAIL: $desc"; fail=1; fi; }
pk=$root/packaging

mkdir -p "$tmp/bin"
cat >"$tmp/bin/gdbus" <<'SH'
#!/bin/sh
echo "gdbus $*" >>"$FAKE_LOG"
case "$*" in *org.freedesktop.DBus.NameHasOwner*) if [ -n "$FAKE_SERVER" ]; then echo "(true,)"; else echo "(false,)"; fi ;; esac
SH
cat >"$tmp/bin/notify-send" <<'SH'
#!/bin/sh
echo "notify-send $*" >>"$FAKE_LOG"
SH
cat >"$tmp/bin/busctl" <<'SH'
#!/bin/sh
echo "busctl $*" >>"$FAKE_LOG"
[ -n "$FAKE_SERVER" ]
SH
cat >"$tmp/bin/omarchy-migrate" <<'SH'
#!/bin/sh
echo 1
SH
printf '#!/bin/sh\necho "systemd-run $*" >>"$FAKE_LOG"\n' >"$tmp/bin/systemd-run"
printf '#!/bin/sh\n' >"$tmp/bin/sleep"   # the migrate wait's 0.5 s naps
chmod +x "$tmp/bin"/*

# --- grassfield-battery-watch ---------------------------------------------------------------------------------------------
cat >"$tmp/battery.py" <<'PY'
import importlib.machinery, importlib.util, os, sys
sys.dont_write_bytecode = True  # no __pycache__ in packaging/bin (it would be packaged)
loader = importlib.machinery.SourceFileLoader("battery", sys.argv[1] + "/packaging/bin/grassfield-battery-watch")
spec = importlib.util.spec_from_loader("battery", loader); m = importlib.util.module_from_spec(spec); loader.exec_module(m)
print("delivered", m.notify(10, 9))
PY
battery() { : >"$tmp/log"; FAKE_LOG=$tmp/log PATH="$tmp/bin:/usr/bin:/bin" python3 -I "$tmp/battery.py" "$root"; }
desc="battery-watch: no notification server: nothing sent (no notify-send), the warning is not counted as given"
out=$(battery)
check bash -c '[[ $1 == "delivered False" ]] && ! grep -q "^notify-send" "$2/log" && grep -q "^gdbus call --session --dest org.freedesktop.DBus .*NameHasOwner org.freedesktop.Notifications" "$2/log"' _ "$out" "$tmp"
desc="battery-watch: the server is there: the warning is sent and counted"
out=$(FAKE_SERVER=1 battery)
check bash -c '[[ $1 == "delivered True" ]] && grep -q "^notify-send -a Grassfield -u normal -- Low battery 9% of the battery is left" "$2/log"' _ "$out" "$tmp"

# --- grassfield-migrate-notify --------------------------------------------------------------------------------------------
migrate() { : >"$tmp/log"; FAKE_LOG=$tmp/log XDG_RUNTIME_DIR=$tmp PATH="$tmp/bin:/usr/bin:/bin" bash "$pk/bin/grassfield-migrate-notify" >/dev/null 2>&1 || true; }
desc="migrate-notify: the wait for the server never activates one (busctl --auto-start=no), and with none nothing is sent"
migrate
check bash -c '[[ $(grep -c "^busctl --user --auto-start=no call org.freedesktop.Notifications" "$1/log") == 60 ]] && ! grep -q "^busctl" <(grep -v -- "--auto-start=no" "$1/log") && ! grep -q "^notify-send" "$1/log"' _ "$tmp"
desc="migrate-notify: the server is there: one look, then the notice"
FAKE_SERVER=1 migrate
check bash -c '[[ $(grep -c "^busctl" "$1/log") == 1 ]] && grep -q "^notify-send -a Grassfield -u critical -w" "$1/log"' _ "$tmp"

exit "$fail"
