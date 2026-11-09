#!/usr/bin/env bash
# The icon A2 harness (tests/visual/icon-a2.sh) must not let a stalled case block the next ones (R7 icon harness, 2026-11-09: on main the
# desktop case stalled and so did every later case, 4 x 240 s each, even the pure data check). A fake runner (GRASSFIELD_ICONS_RUNNER)
# stands in for qmltestrunner, so no nested session or GPU is needed:
#   1. a stalled case is killed, the health probe passes, the later cases still run and pass, the exit status says one stall;
#   2. a wedged session (the probe stalls too) stops the run at once, exit 3, the later cases never start, and the message names them;
#   3. a clean run exits 0 and runs every case once.
set -uo pipefail
root=$(git -C "$(dirname "$0")" rev-parse --show-toplevel)
tmp=$root/.dev/icon-a2-runner-test
rm -rf "$tmp"
mkdir -p "$tmp"
fail=0
ok() { echo "PASS: $1"; }
bad() { echo "FAIL: $1"; fail=1; }

cat >"$tmp/fake.sh" <<'EOF'
#!/usr/bin/env bash
# $1 = IconShaderA2::<function>. FAKE_STALL: function that hangs; FAKE_WEDGE: once a case hung, every later call hangs.
fn=${1#IconShaderA2::}
echo "$fn" >>"$FAKE_LOG"
if [[ -e $FAKE_STATE/wedged ]]; then sleep 600; fi
if [[ $fn == "${FAKE_STALL:-}" ]]; then
  [[ -n ${FAKE_WEDGE:-} ]] && touch "$FAKE_STATE/wedged"
  sleep 600
fi
echo "PASS   : qmltestrunner::IconShaderA2::$fn()"
echo "Totals: 2 passed, 0 failed, 0 skipped, 0 blacklisted, 5ms"
EOF
chmod +x "$tmp/fake.sh"

run() { # name stall wedge -> sets out, status, secs, log
  local name=$1
  export FAKE_LOG=$tmp/$name.log FAKE_STATE=$tmp/$name.state FAKE_STALL=$2 FAKE_WEDGE=$3
  mkdir -p "$FAKE_STATE"
  : >"$FAKE_LOG"
  local t0=$SECONDS
  out=$(GRASSFIELD_ICONS_RUNNER=$tmp/fake.sh GRASSFIELD_ICONS_TIMEOUT=2 GRASSFIELD_ICONS_TIMEOUT_HEAVY=2 GRASSFIELD_ICONS_PROBE_TIMEOUT=2 \
    GRASSFIELD_ICONS_KILL=1 GRASSFIELD_ICONS_WARMUP=2 GRASSFIELD_ICONS_WARMUP_KILL=1 GRASSFIELD_ICONS_ATTEMPTS=2 "$root/tests/visual/icon-a2.sh" test_a2_size48 test_a2_desktop test_a2_size16 test_a2_limitKeysAreWellFormed 2>&1)
  status=$?
  secs=$((SECONDS - t0))
  log=$(cat "$FAKE_LOG")
}

# 4. a session that wedges on the very first client (main, 2026-11-09): the warm-up fails, no case starts
run cold test_a2_limitKeysAreWellFormed ""
[[ $status == 3 ]] && ok "a cold session that never answers: exit 3 from the warm-up" || bad "cold: exit $status: $out"
[[ $(grep -c . <<<"$log") == 1 ]] && ok "only the warm-up ran, no case" || bad "cold: ran $log"
grep -q "warm-up" <<<"$out" && ok "the message names the warm-up" || bad "no warm-up message: $out"

# 3. clean
run clean "" ""
[[ $status == 0 ]] && ok "a clean run exits 0" || bad "a clean run exits $status: $out"
[[ $(grep -c . <<<"$log") == 5 ]] && ok "a clean run: one warm-up and each case once" || bad "a clean run started: $log"

# 1. one stalled case, healthy session
run stall test_a2_desktop ""
[[ $status == 2 ]] && ok "one stalled case: exit 2 (stalled), not 3 (wedged)" || bad "one stalled case: exit $status: $out"
grep -q "test_a2_size16 passed" <<<"$out" && grep -q "test_a2_limitKeysAreWellFormed passed" <<<"$out" && ok "the cases after a stalled one still run and pass" || bad "later cases did not pass: $out"
grep -q "the health probe passed" <<<"$out" && ok "the probe tells a stalled case from a wedged session" || bad "no probe verdict: $out"
[[ $secs -le 40 ]] && ok "bounded: ${secs}s" || bad "took ${secs}s"

# 2. wedged session
run wedge test_a2_desktop 1
[[ $status == 3 ]] && ok "a wedged session stops the run: exit 3" || bad "wedged: exit $status: $out"
grep -q "test_a2_size16" <<<"$log" && bad "a later case started after the wedge: $log" || ok "no later case starts after the wedge"
grep -q "test_a2_size16 test_a2_limitKeysAreWellFormed" <<<"$out" && ok "the message names the cases that did not run" || bad "no list of the remaining cases: $out"
[[ $secs -le 30 ]] && ok "bounded: ${secs}s" || bad "took ${secs}s"

rm -rf "$tmp"
exit "$fail"
