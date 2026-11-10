#!/usr/bin/env bash
# The polkit agent's registration on the REAL Quickshell (ADR-0041 S3; the opus delta review of S3, MAJOR-1: Quickshell's
# PolkitAgent sets its path once, so the retry of 655916ba, a new path, never asked again; the agent is now made again).
# shell/security/polkit/AuthAgent.qml as written, its window an Item (authagent_flows.d/make_harness.py --real), runs
# offscreen in `qs` under authagent_registration.d/probe.qml, with a retry base of 100 ms and the system bus given here:
#   1. nowhere (DBUS_SYSTEM_BUS_ADDRESS names a socket that does not exist): every attempt fails. The attempts, counted from
#      Quickshell's own "failed to register listener on path" lines, are one per agent made (the first, then one per try:
#      none made inert, so never two agents at once), at least 5 in 4.5 s, each wait at least the doubled one before (100,
#      200, 400, 800 ms; a coarse timer may fire 5 % early); Quickshell never says "cannot change path after it has been
#      set."; nothing registers.
#   2. nowhere, in a dev session (GRASSFIELD_DEV=1): one attempt in 1.5 s, no try.
#   3. a private system bus with a fake polkit authority (tests/fixtures/fake-polkit-authority.py) that refuses the first 3
#      registrations, as polkitd refuses a second agent for a session: the 4th agent registers; after it no registration
#      and no unregistration until the probe quits (a registered agent is never let go). SKIP when this process cannot run
#      a private bus (Unix sockets refused, as in a sandbox) or has no logind session (Quickshell then makes no subject and
#      never reaches the bus).
# Never the real system bus: phases 1 and 2 name a socket that does not exist, phase 3 the test's own bus.
#
#   tests/security/authagent_registration.sh             PASS / FAIL lines; exit 0 PASS (phase 3 passed or SKIPped),
#                                                        1 FAIL, 2 environment error; SKIP (exit 0) without qs or python3
#   tests/security/authagent_registration.sh --mutants   also phase 1 on each mutant below, which must fail
#                                                        ("MUTANT <name>: CAUGHT"): the retry of 655916ba by a new path,
#                                                        the next agent made in the same turn, no backoff
set -uo pipefail
root=$(git -C "$(dirname "$0")" rev-parse --show-toplevel)
cd "$root"
mutants=0
case ${1:-} in
  "") ;;
  --mutants) mutants=1 ;;
  *) echo "usage: authagent_registration.sh [--mutants]" >&2; exit 2 ;;
esac
command -v qs >/dev/null || { echo "SKIP: authagent_registration needs qs (Quickshell)"; exit 0; }
command -v python3 >/dev/null || { echo "SKIP: authagent_registration needs python3"; exit 0; }
unset QT_QPA_PLATFORMTHEME
mkdir -p "$root/.dev"
tmp=$(mktemp -d "$root/.dev/authagent-registration.XXXXXX") || { echo "ENVIRONMENT: no scratch directory"; exit 2; }
bus_dir=""
pids=()
cleanup() {
  local p
  for p in "${pids[@]}"; do kill -TERM -- "-$p" 2>/dev/null || kill "$p" 2>/dev/null; done
  wait 2>/dev/null
  rm -rf "$tmp"
  [[ -n $bus_dir ]] && rm -rf "$bus_dir"
}
trap cleanup EXIT
trap 'exit 130' INT
trap 'exit 143' TERM
ui/i18n/build-direct.sh >/dev/null || { echo "ENVIRONMENT: Grassfield.I18n does not build"; exit 2; }

# The scratch config: the agent as written beside its sheet and model, qs.security and the relative lib/ as links.
cfg=$tmp/cfg
mkdir -p "$cfg/real/polkit" "$tmp/runtime" "$tmp/home" "$tmp/cache" "$tmp/state" "$tmp/config"
chmod 700 "$tmp/runtime" "$tmp/cache"
ln -s "$root/shell/security" "$cfg/security"
ln -s "$root/shell/lib" "$cfg/lib"
cp shell/security/polkit/AuthDialog.qml shell/security/polkit/AuthDialogModel.qml "$cfg/real/polkit/"
printf '%s\n' "module qs.real.polkit" "AgentUnderTest 1.0 AgentUnderTest.qml" "AuthDialog 1.0 AuthDialog.qml" \
  "AuthDialogModel 1.0 AuthDialogModel.qml" >"$cfg/real/polkit/qmldir"
cp tests/security/authagent_registration.d/probe.qml "$cfg/shell.qml"
# agent <AuthAgent.qml>: the agent the probe makes.
agent() {
  python3 -I tests/security/authagent_flows.d/make_harness.py --real "$1" "$cfg/real/polkit/AgentUnderTest.qml"
}
agent shell/security/polkit/AuthAgent.qml || { echo "ENVIRONMENT: the harness cannot be made"; exit 2; }

# run <log> <system bus> <retry ms> <run ms> [VAR=value...]: the probe in qs; its log, with times, in <log>.
run() {
  local log=$1 bus=$2 retry=$3 ms=$4
  shift 4
  env -u WAYLAND_DISPLAY -u HYPRLAND_INSTANCE_SIGNATURE -u DISPLAY -u DBUS_SESSION_BUS_ADDRESS \
    -u GRASSFIELD_DEV -u GRASSFIELD_SESSION -u GRASSFIELD_DEV_ALLOW_PAM "$@" \
    DBUS_SYSTEM_BUS_ADDRESS="$bus" REGISTRATION_PROBE_RETRY_MS="$retry" REGISTRATION_PROBE_RUN_MS="$ms" \
    HOME="$tmp/home" GRASSFIELD_STATE_HOME="$tmp/state" GRASSFIELD_CONFIG_HOME="$tmp/config" \
    XDG_RUNTIME_DIR="$tmp/runtime" XDG_CACHE_HOME="$tmp/cache" GRASSFIELD_LANG=en \
    QT_QPA_PLATFORM=offscreen QML_IMPORT_PATH="$root/ui:$root/.dev/build/qml" \
    timeout 60 qs -p "$cfg" --no-color --log-times >"$log" 2>&1 </dev/null
}

# check <phase> <qs log> [authority log]: the phase's rules; PASS/FAIL lines, exit 1 on a failure.
check() {
  python3 -I - "$@" <<'PY'
import datetime
import re
import sys

phase, log = sys.argv[1], sys.argv[2]
lines = open(log, encoding="utf-8", errors="replace").read().splitlines()
ok = True


def say(good, what):
    global ok
    print(("PASS: " if good else "FAIL: ") + "authagent_registration " + phase + ": " + what)
    ok = ok and good


def at(line):
    m = re.match(r"(\d{4}-\d\d-\d\d \d\d:\d\d:\d\d\.\d{3})", line)
    return datetime.datetime.strptime(m.group(1), "%Y-%m-%d %H:%M:%S.%f").timestamp() * 1000 if m else None


def doubling(times, base):
    gaps = [b - a for a, b in zip(times, times[1:])]
    return all(g >= 0.9 * base * 2 ** k for k, g in enumerate(gaps)), [round(g) for g in gaps]


failed = [at(x) for x in lines if "failed to register listener on path" in x]
end = [x for x in lines if "registration-probe: end" in x]
m = re.search(r"tries=(-?\d+) registered=(\w+)", end[0]) if end else None
tries = int(m.group(1)) if m else -1
registered = m.group(2) == "true" if m else None
say(bool(m) and not any("registration-probe: not loaded" in x for x in lines), "the agent loaded and the probe ended (%s)" % (end[0].split("registration-probe: ")[1] if end else "no end line"))
say(not any("cannot change path after it has been set" in x for x in lines), "Quickshell never refused a path")
if phase == "nowhere":
    say(len(failed) == tries + 1, "one attempt per agent made: %d attempts, %d tries (none made inert)" % (len(failed), tries))
    say(tries >= 4, "asked again while refused: %d tries in 4.5 s" % tries)
    good, gaps = doubling(failed, 100)
    say(good, "each wait at least the doubled one before (ms between attempts: %s)" % gaps)
    say(registered is False and not any("authentication agent registered" in x or "registered=true" in x for x in lines), "nothing registered")
elif phase == "dev":
    say(len(failed) == 1 and tries == 0, "one attempt, no try in a dev session (%d attempts, %d tries)" % (len(failed), tries))
elif phase == "authority":
    calls = [x.split() for x in open(sys.argv[3], encoding="utf-8").read().splitlines() if not x.startswith("#")]
    regs = [c for c in calls if c[1] == "register"]
    unregs = [c for c in calls if c[1] == "unregister"]
    end_at = at(end[0]) if end else None
    say([c[3] for c in regs] == ["refused"] * 3 + ["accepted"], "refused three times, then registered: %s" % [c[3] for c in regs])
    say(len(failed) == 3 and tries == 3 and registered is True, "three failures seen by Quickshell, three tries, registered (%d, %d, %s)" % (len(failed), tries, registered))
    good, gaps = doubling([int(c[0]) for c in regs], 100)
    say(good, "each wait at least the doubled one before (ms between registrations: %s)" % gaps)
    say(end_at is not None and all(int(c[0]) >= end_at - 50 for c in unregs) and len(unregs) <= 1,
        "the registered agent kept until the probe quit (unregistrations: %d, all at the end)" % len(unregs))
if not ok:
    print("\n".join("  | " + x for x in lines if re.search(r"ERROR|WARN (qml|quickshell)|registration-probe", x))[:3000])
sys.exit(0 if ok else 1)
PY
}

fail=0
nowhere="unix:path=$tmp/no-system-bus"

run "$tmp/nowhere.log" "$nowhere" 100 4500
check nowhere "$tmp/nowhere.log" || fail=1

run "$tmp/dev.log" "$nowhere" 100 1500 GRASSFIELD_DEV=1
check dev "$tmp/dev.log" || fail=1

# Phase 3: a private system bus (short socket path) with the fake authority.
phase3() {
  command -v dbus-daemon >/dev/null || { echo "SKIP: authagent_registration authority: no dbus-daemon"; return 0; }
  python3 -I -c 'import gi; gi.require_version("Gio", "2.0"); from gi.repository import Gio' 2>/dev/null \
    || { echo "SKIP: authagent_registration authority: no PyGObject"; return 0; }
  bus_dir=$(mktemp -d "${TMPDIR:-/tmp}/gfr.XXXXXX") || { echo "SKIP: authagent_registration authority: no bus directory"; return 0; }
  mkdir -p "$bus_dir/run"
  printf '%s\n' '<!DOCTYPE busconfig PUBLIC "-//freedesktop//DTD D-Bus Bus Configuration 1.0//EN" "http://www.freedesktop.org/standards/dbus/1.0/busconfig.dtd">' \
    '<busconfig>' '  <type>system</type>' "  <listen>unix:path=$bus_dir/system.sock</listen>" '  <auth>EXTERNAL</auth>' \
    '  <policy context="default">' '    <allow send_destination="*"/>' '    <allow own="*"/>' '    <allow receive_sender="*"/>' '  </policy>' '</busconfig>' >"$bus_dir/system.conf"
  setsid env -i PATH="$PATH" HOME="$bus_dir" XDG_RUNTIME_DIR="$bus_dir/run" dbus-daemon --config-file="$bus_dir/system.conf" \
    --nofork --print-address=1 >"$bus_dir/address" 2>"$bus_dir/bus.log" </dev/null &
  pids+=("$!")
  local n=50
  while ((n-- > 0)) && [[ ! -s $bus_dir/address ]]; do sleep 0.1; done
  [[ -s $bus_dir/address ]] || { echo "SKIP: authagent_registration authority: no private dbus-daemon (Unix sockets unavailable?)"; return 0; }
  local bus
  bus=$(head -n 1 "$bus_dir/address")
  setsid env -i PATH="$PATH" GF_TEST_BUS=1 GF_TEST_BUS_DIR="$bus_dir" DBUS_SYSTEM_BUS_ADDRESS="$bus" \
    python3 -I tests/fixtures/fake-polkit-authority.py --log "$tmp/authority.log" --refuse 3 </dev/null >"$tmp/authority.out" 2>&1 &
  pids+=("$!")
  n=50
  while ((n-- > 0)) && ! grep -qx '#owned' "$tmp/authority.log" 2>/dev/null; do sleep 0.1; done
  grep -qx '#owned' "$tmp/authority.log" 2>/dev/null || { echo "FAIL: authagent_registration authority: the fake authority did not start ($(head -c 300 "$tmp/authority.out"))"; return 1; }
  run "$tmp/authority-qs.log" "$bus" 100 3000
  if grep -q 'failed to create subject for listener' "$tmp/authority-qs.log"; then
    echo "SKIP: authagent_registration authority: this process has no logind session (Quickshell makes no subject)"
    return 0
  fi
  check authority "$tmp/authority-qs.log" "$tmp/authority.log"
}
phase3 || fail=1

# Each mutant: <name>#<text in AuthAgent.qml, once>#<its replacement> (\n a newline); phase 1 must fail on it.
if ((mutants)); then
  while IFS= read -r line; do
    [[ -n $line ]] || continue
    IFS='#' read -r -a f <<<"$line"
    python3 -I - shell/security/polkit/AuthAgent.qml "$tmp/mutant.qml" "${f[1]}" "${f[2]}" <<'PY' || { echo "MUTANT ${f[0]}: NOT APPLIED (its text is not there once)"; fail=1; continue; }
import sys
src, out, old, new = sys.argv[1], sys.argv[2], sys.argv[3].replace("\\n", "\n"), sys.argv[4].replace("\\n", "\n")
text = open(src).read()
if text.count(old) != 1:
    sys.exit(3)
open(out, "w").write(text.replace(old, new))
PY
    agent "$tmp/mutant.qml" || { echo "MUTANT ${f[0]}: NOT APPLIED (no harness)"; fail=1; continue; }
    run "$tmp/mutant.log" "$nowhere" 100 4500
    if check nowhere "$tmp/mutant.log" >/dev/null; then echo "MUTANT ${f[0]}: NOT CAUGHT"; fail=1; else echo "MUTANT ${f[0]}: CAUGHT"; fi
  done <<'EOF_MUTANTS'
the retry of 655916ba, a new path (S3 delta review MAJOR-1)#        agentHolder.active = false;\n        agentRemake.restart();#        root.agent.path = root.agentPath + "/" + root.registrationTries;
the next agent made in the same turn (S3 delta review MAJOR-1)#        agentHolder.active = false;\n        agentRemake.restart();#        agentHolder.active = false;\n        agentHolder.active = true;
no backoff (S3 review MINOR-3)#        interval: root.registrationRetryInterval#        interval: root.registrationRetryMs
EOF_MUTANTS
  agent shell/security/polkit/AuthAgent.qml
fi

((fail == 0)) && echo "PASS: authagent_registration" || echo "FAIL: authagent_registration"
exit "$fail"
