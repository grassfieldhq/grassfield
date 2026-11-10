#!/usr/bin/env bash
# Gate A2 for the icon appearance modes: tests/unit/tst_iconshader.qml needs a GPU scene graph (ShaderEffect does not run
# on the software renderer of the offscreen platform, where the test skips), so it runs as a Wayland client of this
# tree's NESTED session (scripts/dev/nested-up.sh first). Run it as a bare command. Prints the per-icon contrast lines
# ("A2 ...") and exits 0 when every rule holds.
#
# A renderer can stall when the GPU is shared with other nested sessions (a swap that never completes). Every test function
# (a size, the desktop, the folder model, the missing-shader fallback) runs in a process of its own under a watchdog and a
# stalled attempt is retried: a stall costs one case, not the whole run. A real failure (a FAIL line) is never retried.
#
# What a stall must not do (R7 icon harness, 2026-11-09: on main the four size cases passed, then the desktop case stalled and so did
# every later case, even the pure data check limitKeysAreWellFormed, each for 4 x 240 s = 2.5 h with no data): after a stalled attempt
#   1. the watchdog's process group is killed (timeout kills the group; a sweep of this tree's qmltestrunner follows),
#   2. a HEALTH PROBE runs: the pure data case under a short limit. If it stalls too, the nested session or its GPU context is wedged
#      and no later case can run: the run stops at once (exit 3), naming the cases that did not run, instead of burning every
#      remaining case's attempts. Restart the nested session (scripts/dev/nested-down.sh, scripts/dev/nested-up.sh) and run the
#      remaining cases by name.
#   3. a heavy case (several scenarios: desktop, transparency, tints, accent row) gets a longer limit than a size case.
#   4. a WARM-UP before the first case: on main (2026-11-09, load 1.7) the very first case after nested-up stalled and the health probe
#      stalled with it, so the first GPU client of a fresh nested session is slow or wedges. The pure data case runs first under a long
#      limit (GRASSFIELD_ICONS_WARMUP, default 300 s, TERM then a 60 s grace before KILL so the client can leave cleanly); if it does
#      not finish the session is unusable and the run stops at once (exit 3) before any case starts.
#   6. NO WAIT FOR FRAME CALLBACKS. Rendering cases (not the data case) hung on GF-REF although the window was mapped there (2026-11-09 evening).
#      Qt Quick's grabs render in the window's render loop, which swaps; Mesa's EGL Wayland swap with swap interval 1 blocks until the compositor
#      answers the frame callback of the previous frame, with no timeout, and the compositor answers only for what it presents on screen. The
#      cases need no presentation (they read their own offscreen grabs), so qmltestrunner starts with vblank_mode=0 (Mesa: swap interval 0, no
#      throttle). GRASSFIELD_ICONS_VBLANK=1 restores the old behaviour (an A/B without editing the script).
#   5. THE OUTPUT. In the nested session a window that maps on WAYLAND-1 (the nested compositor's own window on the owner's screen) only gets
#      frame callbacks while that window is visible there, and never otherwise: every case then waits for a frame that does not come
#      (2026-11-09: even the pure data case, which only needs its window shown, never finished, on main and on the branch, at load 6;
#      the size cases had passed earlier, when the window happened to be visible). GF-REF is headless and renders regardless, as for
#      tests/visual/lib.sh (VS_OUTPUT). So before every attempt the runner focuses GF-REF and parks the pointer on it (new windows map on
#      the focused monitor), and the warm-up reads, from the nested `clients` and `monitors`, the output the test window landed on: it prints
#      it, and fails with that reason (exit 3) when it is not GF-REF or when no window appeared.
#
#   tests/visual/icon-a2.sh [test_function ...]
#
# Environment: GRASSFIELD_ICONS_TIMEOUT (a size case, s, default 240), GRASSFIELD_ICONS_TIMEOUT_HEAVY (default 480),
# GRASSFIELD_ICONS_PROBE_TIMEOUT (default 60), GRASSFIELD_ICONS_ATTEMPTS (default 2), GRASSFIELD_ICONS_KILL (s between TERM and
# KILL, default 10). GRASSFIELD_ICONS_RUNNER: a command that runs one case instead of qmltestrunner (it receives
# "IconShaderA2::<function>" and prints the qmltestrunner lines); used by tests/shell/icon_a2_runner.sh, no nested session is needed then.
set -uo pipefail

root=$(git -C "$(dirname "$0")" rev-parse --show-toplevel)
dev=$root/.dev
runner=${GRASSFIELD_ICONS_RUNNER:-}
if [[ -z $runner ]]; then
  # shellcheck source=pidfile.sh
  . "$root/scripts/dev/pidfile.sh"
  dev_nested_target "$dev" || { echo "test-icons: no nested session of this tree (scripts/dev/nested-up.sh)" >&2; exit 1; }
fi
mkdir -p "$dev"
limit=${GRASSFIELD_ICONS_TIMEOUT:-240}
heavy=${GRASSFIELD_ICONS_TIMEOUT_HEAVY:-480}
probe_limit=${GRASSFIELD_ICONS_PROBE_TIMEOUT:-60}
attempts=${GRASSFIELD_ICONS_ATTEMPTS:-2}
kill_after=${GRASSFIELD_ICONS_KILL:-10}
probe_fn=test_a2_limitKeysAreWellFormed
want_output=${GRASSFIELD_ICONS_OUTPUT:-GF-REF}
warmup=${GRASSFIELD_ICONS_WARMUP:-300}
warm_kill=${GRASSFIELD_ICONS_WARMUP_KILL:-60}
cases=("$@")
[[ ${#cases[@]} -gt 0 ]] || cases=(test_a2_size48 test_a2_size32 test_a2_size24 test_a2_size16 test_a2_desktop test_a2_dock test_a2_transparent48 test_a2_transparent24 test_a2_transparent16 test_a2_tintYellow32 test_a2_tintPink32 test_a2_accentRow test_a2_filesSelectedRow test_a2_limitKeysAreWellFormed test_folderModelMatchesTheShader test_blackFolderKeepsItsPlateOnBlack test_missingShaderDrawsThePlainIcon)

limit_of() {
  case $1 in
    test_a2_desktop | test_a2_dock | test_a2_transparent* | test_a2_tint* | test_a2_accentRow | test_a2_filesSelectedRow) echo "$heavy" ;;
    test_a2_limitKeysAreWellFormed) echo "$probe_limit" ;;
    *) echo "$limit" ;;
  esac
}

# Focus the reference output and park the pointer on it, so the next window maps there (nested session only).
pin_output() {
  [[ -n $runner ]] && return 0
  timeout 10 "$root/scripts/nestctl" dispatch "hl.dsp.focus({ monitor = '$want_output' })" >/dev/null 2>&1 || echo "test-icons: could not focus $want_output" >&2
  timeout 20 "$root/scripts/dev/pointer.sh" output "$want_output" abs 100 100 >/dev/null 2>&1 || true
}

# The output the test window sits on, or nothing while there is no such window. GRASSFIELD_ICONS_OUTPUT_PROBE replaces the query (tests).
window_output() {
  if [[ -n ${GRASSFIELD_ICONS_OUTPUT_PROBE:-} ]]; then
    "$GRASSFIELD_ICONS_OUTPUT_PROBE" 2>/dev/null
    return 0
  fi
  [[ -n $runner ]] && return 0
  local mid
  mid=$(timeout 10 "$root/scripts/nestctl" clients -j 2>/dev/null | jq -r '[.[] | select(((.class // "") + " " + (.initialClass // "")) | test("qmltestrunner"; "i"))] | .[0].monitor // empty' 2>/dev/null)
  [[ -n $mid ]] || return 0
  timeout 10 "$root/scripts/nestctl" monitors -j 2>/dev/null | jq -r --argjson id "$mid" '.[] | select(.id == $id) | .name' 2>/dev/null
}

# One attempt of one case: prints the qmltestrunner output; the exit status is the watchdog's (124 / 137: stalled).
run_one() {
  local fn=$1 lim=$2
  pin_output
  if [[ -n $runner ]]; then
    timeout -k "$kill_after" "$lim" "$runner" "IconShaderA2::$fn" 2>&1
  else
    timeout -k "$kill_after" "$lim" "$root/scripts/dev/isolated.sh" --name "a2-$$" env WAYLAND_DISPLAY="$DEV_NESTED_SOCK" QT_QPA_PLATFORM=wayland QML_XHR_ALLOW_FILE_READ=1 vblank_mode="${GRASSFIELD_ICONS_VBLANK:-0}" \
      /usr/lib/qt6/bin/qmltestrunner -import "$root/ui" -input "$root/tests/unit/tst_iconshader.qml" "IconShaderA2::$fn" 2>&1
  fi
}

# Whatever survived a killed attempt (this tree's runner only; never anything else).
sweep() {
  [[ -n $runner ]] || pkill -KILL -f -- "qmltestrunner .*-input $root/tests/unit/tst_iconshader.qml" 2>/dev/null || true
}

# The nested session answers: the pure data case runs to its Totals line within the probe limit.
healthy() {
  local out status
  out=$(run_one "$probe_fn" "$probe_limit")
  status=$?
  [[ $status != 124 && $status != 137 ]] && grep -q 'Totals' <<<"$out"
}

# Warm-up: the first GPU client of a fresh nested session, run in the background so that the output of its window can be read while it runs.
warm_tmp=$(mktemp "$dev/icon-a2-warm.XXXXXX")
trap 'rm -f "$warm_tmp"' EXIT
( kill_after=$warm_kill run_one "$probe_fn" "$warmup" >"$warm_tmp" 2>&1 ) &
warm_pid=$!
landed=""
while kill -0 "$warm_pid" 2>/dev/null; do
  if [[ -z $landed ]]; then
    landed=$(window_output)
    if [[ -n $landed ]]; then
      echo "test-icons: the test window landed on output $landed" >&2
      if [[ $landed != "$want_output" ]]; then
        pkill -KILL -P "$warm_pid" 2>/dev/null || true
        kill -KILL "$warm_pid" 2>/dev/null || true
        sweep
        echo "test-icons: the warm-up window is on $landed, not $want_output: it gets no frame callbacks there unless that output is visible, so no case could finish (exit 3)." >&2
        echo "test-icons: focus $want_output in the nested session (scripts/nestctl dispatch \"hl.dsp.focus({ monitor = '$want_output' })\") or restart it." >&2
        exit 3
      fi
    fi
  fi
  sleep 1
done
wait "$warm_pid"
status=$?
out=$(cat "$warm_tmp")
if [[ $status == 124 || $status == 137 ]] || ! grep -q 'Totals' <<<"$out"; then
  if [[ -n $landed ]]; then
    echo "test-icons: the warm-up ($probe_fn, ${warmup}s) did not finish although its window is on $landed: the nested session is wedged (exit $status)." >&2
  else
    echo "test-icons: the warm-up ($probe_fn, ${warmup}s) did not finish and no qmltestrunner window ever appeared in the nested clients: the output is unknown, the client never mapped (exit $status)." >&2
  fi
  echo "test-icons: restart the nested session (scripts/dev/nested-down.sh, scripts/dev/nested-up.sh) and run again." >&2
  exit 3
fi

overall=0
remaining=("${cases[@]}")
for fn in "${cases[@]}"; do
  remaining=("${remaining[@]:1}")
  done_case=0
  for ((try = 1; try <= attempts; try++)); do
    out=$(run_one "$fn" "$(limit_of "$fn")")
    status=$?
    # A stall: killed by the watchdog, or no result at all (the runner died before reporting).
    if [[ $status == 124 || $status == 137 ]] || ! grep -q 'Totals' <<<"$out"; then
      echo "test-icons: $fn attempt $try stalled (exit $status, limit $(limit_of "$fn")s)" >&2
      sweep
      if ! healthy; then
        echo "test-icons: the health probe ($probe_fn, ${probe_limit}s) stalled too: the nested session or its GPU context is wedged." >&2
        echo "test-icons: stopping. Restart it (scripts/dev/nested-down.sh, scripts/dev/nested-up.sh) and run the cases that did not run by name: $fn ${remaining[*]}" >&2
        exit 3
      fi
      echo "test-icons: the health probe passed, the stall is this case's" >&2
      continue
    fi
    echo "$out" | grep -E "A2 " >>"$dev/a2-last.log" || true
    echo "$out" | grep -E "^PASS|^FAIL|^SKIP|Totals"
    if [[ $status != 0 ]] || grep -qE '^FAIL|^SKIP' <<<"$out"; then
      echo "$out" | sed -n '/failures:/,/Loc:/p' | head -80
      echo "test-icons: $fn FAILED"
      overall=1
    else
      echo "test-icons: $fn passed (attempt $try)"
    fi
    done_case=1
    break
  done
  if [[ $done_case == 0 ]]; then
    echo "test-icons: $fn: every attempt stalled" >&2
    overall=2
  fi
done
exit "$overall"
